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
            let plan = ReapPlan(key: full.key,
                                processes: full.processes.filter { $0.pid != me },
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
