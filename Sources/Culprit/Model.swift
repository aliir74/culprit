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

    /// Stops leftover groups from a fresh reading, never from the one on screen: a pid
    /// seconds old may already belong to something else. Live sessions are never stopped.
    func stop(_ keys: [AttributionKey]) async {
        let ids = Set(keys.map { "\($0)" })
        stopping.formUnion(ids)
        defer { stopping.subtract(ids) }
        message = nil

        guard let (snapshot, sample, _) = await collect() else {
            message = "Could not read the machine. Nothing was stopped."
            return
        }
        guard sample.roster.allowsReaping else {
            message = "The session list could not be read, so live sessions could look "
                + "abandoned. Nothing was stopped."
            return
        }
        let keep = Reaper.keepMarkedWorktrees(in: sample)
        var stopped = 0
        var survived = 0
        for key in keys {
            guard let group = snapshot.orphans.first(where: { $0.key == key }) else { continue }
            let plan = AttributionEngine.reapPlan(
                for: group.key, processes: sample.processes,
                environments: sample.environments, containers: sample.containers,
                roster: sample.roster, keepMarkedWorktrees: keep, scope: .attributed)
            guard !plan.isEmpty else { continue }
            let outcome = await Task.detached(priority: .userInitiated) {
                Reaper().execute(plan)
            }.value
            stopped += outcome.terminated.count + outcome.killed.count
                + outcome.containersStopped.count
            survived += outcome.survived.count
        }
        if survived > 0 { message = "\(survived) process(es) would not stop." }
        else if stopped == 0 { message = "Nothing left to stop." }
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
