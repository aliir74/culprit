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
    @Published private(set) var ownCPU: Double?
    @Published private(set) var stopping: Set<String> = []
    /// Agent rows Culprit has paused, by row id. Mirrored to `PauseStore` on every change.
    @Published private(set) var paused: [String: [PausedProcess]] = [:]
    @Published private(set) var pausing: Set<String> = []
    @Published var message: String?
    @Published var interval: Double = UserDefaults.standard.object(forKey: "interval") as? Double ?? 3 {
        didSet { UserDefaults.standard.set(interval, forKey: "interval") }
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

    var menuBarTitle: String {
        guard let busy = data?.header.busyPercent else { return "—" }
        return "\(Int(busy.rounded()))%"
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
            let plan = ReapPlan(key: full.key,
                                processes: full.processes.filter {
                                    $0.pid != me && !held.contains($0.pid)
                                },
                                containers: full.containers, refusal: full.refusal)
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
        PauseStore.save(paused)
        // The session's root goes first, so it cannot react to its children stopping.
        let stopped = await Task.detached(priority: .userInitiated) {
            planned.filter { $0.isSame && kill($0.pid, SIGSTOP) == 0 }
        }.value
        paused[id] = stopped.isEmpty ? nil : stopped
        PauseStore.save(paused)
        if stopped.isEmpty { message = "Nothing to pause." }
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

    /// Drops pauses whose processes have all exited, so a session killed while paused
    /// does not stay recorded forever.
    private func forgetEndedPauses() {
        let alive = paused.filter { $0.value.contains(where: \.isSame) }
        guard alive.count != paused.count else { return }
        paused = alive
        if !pausesReadOnly { PauseStore.save(paused) }
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
