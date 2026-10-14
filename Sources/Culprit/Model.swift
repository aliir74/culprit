import ClaudeTopKit
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class Model: ObservableObject {
    static let shared = Model()

    @Published private(set) var data: PanelData?
    /// Recent CPU per row id, oldest first, for the sparklines.
    @Published private(set) var history: [String: [Double]] = [:]
    /// Recent whole-machine busy percent, oldest first, for the menu bar graph.
    @Published private(set) var machineHistory: [Double] = []
    @Published private(set) var ownCPU: Double?
    @Published private(set) var stopping: Set<String> = []
    /// Agent rows Culprit has paused, by row id. Mirrored to `PauseStore` on every change.
    @Published private(set) var paused: [String: [PausedProcess]] = [:]
    @Published private(set) var pausing: Set<String> = []
    @Published var message: String?
    @Published var interval: Double = UserDefaults.standard.object(forKey: "interval") as? Double ?? 3 {
        didSet { UserDefaults.standard.set(interval, forKey: "interval") }
    }
    @Published var indicator: IndicatorStyle = UserDefaults.standard.string(forKey: "indicator")
        .flatMap(IndicatorStyle.init(rawValue:)) ?? .cores {
        didSet { UserDefaults.standard.set(indicator.rawValue, forKey: "indicator") }
    }

    private let historyLength = 24
    private let collector = IncrementalCollector()
    private let bundles = BundleCache()
    private var previous: [ProcessSample] = []
    private var previousAt = Date()
    private var previousTicks: CPUTicks?
    private var ticker: Task<Void, Never>?
    private var busy = false
    /// Set by `--snapshot`, which shows another Culprit's pauses and must not rewrite them.
    private var pausesReadOnly = false

    /// Icon of the app whose agent is busiest, once that agent uses half a core or more.
    /// With no agent that busy, the busiest other app, so a loaded machine never shows
    /// a bare glyph.
    var busiestAppIcon: NSImage? {
        guard let data else { return nil }
        let agent = data.agents.filter { ($0.cpu ?? 0) >= 50 }.max { ($0.cpu ?? 0) < ($1.cpu ?? 0) }
        let app = data.apps.filter { $0.cpu >= 50 }.max { $0.cpu < $1.cpu }
        guard agent != nil || app != nil else { return nil }
        // A process outside any app bundle (WebContent, a script) gets the generic app icon.
        let bundle = agent.map { $0.appBundle } ?? app?.appBundle
        return bundle.flatMap(IconCache.icon(for:)) ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }

    var severity: Color {
        guard let header = data?.header, let busy = header.busyPercent else { return .secondary }
        if busy > 85 || header.queuedThreads > Double(header.cpuCount) * 2 { return .red }
        if busy > 55 { return .orange }
        return .green
    }

    func start() {
        guard ticker == nil else { return }
        PauseStore.recover()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(self?.interval ?? 3))
            }
        }
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard let (snapshot, sample, cpu) = await collect() else { return }
        let bundles = self.bundles
        let built = await Task.detached(priority: .utility) {
            PanelBuilder.build(snapshot: snapshot, sample: sample, cpu: cpu, bundles: bundles)
        }.value
        ownCPU = cpu[getpid()]
        forgetEndedPauses()
        record(built)
        data = built
    }

    private func record(_ data: PanelData) {
        var next: [String: [Double]] = [:]
        for row in data.agents {
            var series = history[row.id] ?? []
            series.append(row.cpu ?? 0)
            next[row.id] = Array(series.suffix(historyLength))
        }
        history = next
        if let busy = data.header.busyPercent {
            machineHistory = Array((machineHistory + [busy]).suffix(historyLength))
        }
    }

    /// Lifted from claude-top's app: sampling reads process environments and shells out to
    /// docker, so it runs detached and only the deltas cross back to the main actor.
    private func collect() async -> (Snapshot, RawSample, [Int32: Double])? {
        let baseline = previous
        let baselineAt = previousAt
        let baselineTicks = previousTicks
        let collector = self.collector

        let result = await Task.detached(priority: .utility) {
            () -> (Snapshot, RawSample, [Int32: Double])? in
            let listing = ContainerCollector.current(timeout: 5)
            let roster = SessionRoster.live()
            let sample = collector.collect(containers: listing.containers,
                                           dockerAnswered: listing.answered,
                                           roster: roster)
            let cpu = AttributionEngine.cpuPercents(
                earlier: baseline, earlierAt: baselineAt,
                later: sample.processes, laterAt: sample.processesReadAt)
            return (Sampler.attribute(sample, cpuPercents: cpu, previousTicks: baselineTicks),
                    sample, cpu)
        }.value

        if let result {
            previous = result.1.processes
            previousAt = result.1.processesReadAt
            previousTicks = result.1.machine.cpuTicks
        }
        return result
    }

    // MARK: - stopping leftovers

    /// Stops leftover groups. Each group is planned from its own fresh reading, never from
    /// the one on screen or one taken before an earlier group's five-second grace period:
    /// in that time a live session can adopt a process and a pid can be recycled.
    /// Live sessions are never stopped, and neither is Culprit itself.
    func stop(_ keys: [AttributionKey]) async {
        let ids = Set(keys.map { "\($0)" })
        stopping.formUnion(ids)
        defer { stopping.subtract(ids) }
        message = nil

        var stopped = 0
        var kept = 0
        var failures: [String] = []
        for key in keys {
            guard let (snapshot, sample, _) = await collect() else {
                failures.append("could not read the machine")
                break
            }
            guard sample.roster.allowsReaping else {
                failures.append("the session list could not be read, so live sessions "
                                + "could look abandoned")
                break
            }
            guard let group = snapshot.orphans.first(where: { $0.key == key }) else { continue }
            let full = AttributionEngine.reapPlan(
                for: group.key, processes: sample.processes,
                environments: sample.environments, containers: sample.containers,
                roster: sample.roster, keepMarkedWorktrees: Reaper.keepMarkedWorktrees(in: sample),
                scope: .attributed)
            let me = getpid()
            // A paused session never answers, so if it ever drops out of the session list
            // its processes would read as leftovers. Paused is not abandoned.
            let held = Set(paused.values.joined().filter(\.isSame).map(\.pid))
            // reapPlan picks Compose containers by worktree alone. When a live session
            // works in the same worktree as the leftovers, the containers are its too.
            let liveWorktrees = Set(sample.roster.sessions.compactMap {
                Self.worktree(of: $0.cwd)
            })
            let containers = full.containers.filter {
                Self.worktree(of: $0.workingDirectory).map { !liveWorktrees.contains($0) } ?? true
            }
            kept += full.containers.count - containers.count
            let plan = ReapPlan(key: full.key,
                                processes: full.processes.filter {
                                    $0.pid != me && !held.contains($0.pid)
                                },
                                containers: containers, refusal: full.refusal)
            guard !plan.isEmpty else { continue }

            // Pin each pid to the process it named when planned. A pid whose start time
            // has changed is a different process and is neither signalled nor waited on.
            let started = Dictionary(sample.processes.map { ($0.pid, $0.startedAt) },
                                     uniquingKeysWith: { a, _ in a })
            let same: @Sendable (Int32) -> Bool = { pid in
                guard let expected = started[pid], let now = ProcInfo.startTime(pid) else {
                    return false
                }
                return abs(now.timeIntervalSince(expected)) < 1
            }
            let reaper = Reaper(signaller: { pid, signal in same(pid) && kill(pid, signal) == 0 },
                                isAlive: { pid in same(pid) && kill(pid, 0) == 0 })
            let outcome = await Task.detached(priority: .userInitiated) {
                reaper.execute(plan)
            }.value

            stopped += outcome.terminated.count + outcome.containersStopped.count
            if !outcome.survived.isEmpty {
                failures.append("\(outcome.survived.count) process(es) would not stop")
            }
            let failedContainers = plan.containers.count - outcome.containersStopped.count
            if failedContainers > 0 {
                failures.append("\(failedContainers) container(s) would not stop")
            }
        }
        if kept > 0 {
            failures.append("kept \(kept) container(s) a live session in the same worktree uses")
        }
        if !failures.isEmpty {
            message = failures.joined(separator: "; ").prefix(1).uppercased()
                + failures.joined(separator: "; ").dropFirst() + "."
        } else if stopped == 0 {
            message = "Nothing left to stop."
        }
        await refresh()
    }

    // MARK: - pausing sessions

    /// Stops a whole session with `SIGSTOP`, its own `claude` process included. Pausing
    /// only the children would leave Claude's Bash tool timing them out and killing them.
    /// Planned from a fresh reading, like `stop`, and recorded on disk before the first
    /// signal so a crash part way through still leaves something for the next launch to
    /// undo.
    func pause(_ key: AttributionKey) async {
        let id = "\(key)"
        guard paused[id] == nil, !pausing.contains(id) else { return }
        pausing.insert(id)
        defer { pausing.remove(id) }
        message = nil

        guard let (snapshot, sample, _) = await collect() else {
            message = "Could not read the machine."
            return
        }
        guard sample.roster.allowsReaping else {
            message = "The session list could not be read, so pausing is off."
            return
        }
        guard let group = snapshot.sessions.first(where: { $0.key == key }) else {
            message = "That session has ended."
            return
        }
        let planned = members(of: group, in: sample)
        guard !planned.isEmpty else {
            message = "Nothing to pause."
            return
        }

        paused[id] = planned
        guard PauseStore.save(paused) else {
            paused[id] = nil
            message = "Could not record the pause on disk, so nothing was paused."
            return
        }
        // Signalled here on the main actor rather than detached, because
        // `applicationWillTerminate` runs here too: a quit cannot land between the record
        // and the signals and leave a process stopped with nothing left to resume it. The
        // session's root goes first, so it cannot react to its children stopping.
        var stopped = planned.filter { $0.isSame && kill($0.pid, SIGSTOP) == 0 }
        paused[id] = stopped.isEmpty ? nil : stopped
        PauseStore.save(paused)
        if stopped.isEmpty {
            message = "Nothing to pause."
            return
        }

        // A child can fork between the reading and its own stop. Read again until the
        // group holds nothing new; with the root stopped, that settles within a pass or two.
        for _ in 0..<3 {
            guard let (snapshot, sample, _) = await collect(), paused[id] != nil,
                  let group = snapshot.sessions.first(where: { $0.key == key }) else { break }
            let known = Set(stopped.map(\.pid))
            let late = members(of: group, in: sample).filter { !known.contains($0.pid) }
            guard !late.isEmpty else { break }
            paused[id] = stopped + late
            guard PauseStore.save(paused) else { break }
            stopped += late.filter { $0.isSame && kill($0.pid, SIGSTOP) == 0 }
            paused[id] = stopped
            PauseStore.save(paused)
        }
        await refresh()
    }

    /// Sends `SIGCONT` to what was paused, then to the group as it reads now, in case the
    /// record missed anything.
    func resume(_ key: AttributionKey) async {
        let id = "\(key)"
        guard !pausing.contains(id) else { return }
        pausing.insert(id)
        defer { pausing.remove(id) }
        message = nil

        // Children before the root, so the root wakes to children already running.
        let recorded = Array((paused[id] ?? []).reversed())
        await Task.detached(priority: .userInitiated) { _ = PauseStore.resume(recorded) }.value

        if let (snapshot, sample, _) = await collect(),
           let group = snapshot.sessions.first(where: { $0.key == key }) {
            let current = Array(members(of: group, in: sample).reversed())
            await Task.detached(priority: .userInitiated) { _ = PauseStore.resume(current) }.value
        }
        paused[id] = nil
        PauseStore.save(paused)
        await refresh()
    }

    /// Resumes everything Culprit paused. Synchronous, for `applicationWillTerminate`.
    func resumeAllNow() {
        for processes in paused.values { PauseStore.resume(processes.reversed()) }
        paused = [:]
        PauseStore.save(paused)
    }

    /// Shows what an already running Culprit has paused, without touching it. For
    /// `--snapshot`, which runs beside the installed app and must not undo its pauses.
    func showRecordedPauses() {
        pausesReadOnly = true
        paused = PauseStore.load()
    }

    /// A session's processes pinned to their start times, root first. Never Culprit
    /// itself, and never another live session's root, which can sit in this group when
    /// one session started another.
    private func members(of group: AttributionGroup, in sample: RawSample) -> [PausedProcess] {
        let started = Dictionary(sample.processes.map { ($0.pid, $0.startedAt) },
                                 uniquingKeysWith: { a, _ in a })
        let me = getpid()
        let otherRoots = Set(sample.roster.sessions.map(\.pid).filter { $0 != group.sessionPID })
        var pids = group.pids.filter { $0 != group.sessionPID }
        if let root = group.sessionPID { pids.insert(root, at: 0) }
        return pids.compactMap { pid in
            guard pid > 1, pid != me, !otherRoots.contains(pid),
                  let startedAt = started[pid] else { return nil }
            return PausedProcess(pid: pid, startedAt: startedAt)
        }
    }

    /// Drops pauses whose session root has exited. Whatever it left stopped is resumed,
    /// because with the session gone its row is gone too, and nothing could resume them.
    private func forgetEndedPauses() {
        let ended = paused.filter { !($0.value.first?.isSame ?? false) }
        guard !ended.isEmpty else { return }
        for id in ended.keys { paused[id] = nil }
        guard !pausesReadOnly else { return }
        for processes in ended.values { PauseStore.resume(processes.reversed()) }
        PauseStore.save(paused)
    }

    /// The worktree a path is in, matched the way ClaudeTopKit's `worktreeID(forPath:)`
    /// matches it (internal there): the repo folder before the marker, the worktree after.
    nonisolated static func worktree(of path: String) -> String? {
        guard let marker = path.range(of: "/.claude/worktrees/"),
              let repo = path[..<marker.lowerBound].split(separator: "/").last,
              let worktree = path[marker.upperBound...].split(separator: "/").first
        else { return nil }
        return "\(repo)/\(worktree)"
    }

    // MARK: - login item

    var startsAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setStartsAtLogin(_ wanted: Bool) {
        do {
            if wanted { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Login item: \(error.localizedDescription). Install into /Applications first."
        }
        objectWillChange.send()
    }
}
