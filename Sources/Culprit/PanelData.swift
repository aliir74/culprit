import ClaudeTopKit
import Foundation

/// Everything the panel shows, built off the main actor from one engine reading.
struct PanelData: Sendable {
    struct Header: Sendable {
        let busyPercent: Double?
        let busyCores: Double?
        let cpuCount: Int
        let queuedThreads: Double
        let memUsed: UInt64
        let memTotal: UInt64
        let agentCores: Double
        let unaccountedCores: Double?
        let hiddenProcesses: Int
        let totalProcesses: Int
    }

    struct PathLine: Sendable, Identifiable {
        let path: String          // absolute, or "" when unreadable
        let display: String
        let cpu: Double
        let rss: UInt64
        let names: String
        var id: String { path }
    }

    struct AgentRow: Sendable, Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let detail: String?
        let cpu: Double?
        let rss: UInt64
        let appBundle: String?
        let folder: String?
        let paths: [PathLine]
    }

    struct LeftoverRow: Sendable, Identifiable {
        let id: String
        let key: AttributionKey
        let title: String
        let detail: String?
        let cpu: Double?
        let rss: UInt64
        let containers: Int
        let age: TimeInterval?
    }

    struct AppRow: Sendable, Identifiable {
        let id: String
        let name: String
        let appBundle: String?
        let cpu: Double
        let rss: UInt64
        let count: Int
    }

    let header: Header
    let agents: [AgentRow]
    let leftovers: [LeftoverRow]
    let apps: [AppRow]
    let canStop: Bool
}

/// Resolves pids to app bundles, cached for the life of a pid.
final class BundleCache: @unchecked Sendable {
    private var byPID: [Int32: (startedAt: Date, bundle: String?, executable: String?)] = [:]
    private let lock = NSLock()

    func lookup(_ process: ProcessSample) -> (bundle: String?, executable: String?) {
        lock.lock(); defer { lock.unlock() }
        if let hit = byPID[process.pid], hit.startedAt == process.startedAt {
            return (hit.bundle, hit.executable)
        }
        let executable = ProcInfo.executablePath(process.pid)
        let bundle = executable.flatMap(ProcInfo.appBundle(ofExecutable:))
        byPID[process.pid] = (process.startedAt, bundle, executable)
        return (bundle, executable)
    }

    func prune(keeping pids: Set<Int32>) {
        lock.lock(); defer { lock.unlock() }
        byPID = byPID.filter { pids.contains($0.key) }
    }
}

enum PanelBuilder {
    static func build(snapshot: Snapshot, sample: RawSample, cpu: [Int32: Double],
                      bundles: BundleCache) -> PanelData {
        let byPID = Dictionary(sample.processes.map { ($0.pid, $0) },
                               uniquingKeysWith: { a, _ in a })
        bundles.prune(keeping: Set(byPID.keys))

        let machine = snapshot.machine
        let header = PanelData.Header(
            busyPercent: snapshot.systemCPU?.busyPercent,
            busyCores: snapshot.busyCores,
            cpuCount: machine.cpuCount,
            queuedThreads: snapshot.queuedThreads,
            memUsed: machine.memUsedBytes,
            memTotal: machine.memTotalBytes,
            agentCores: snapshot.sessions.reduce(0) { $0 + ($1.cpuPercent ?? 0) } / 100,
            unaccountedCores: snapshot.unaccountedCPUPercent.map { $0 / 100 },
            hiddenProcesses: max(0, machine.processCount - sample.processes.count),
            totalProcesses: machine.processCount)

        let sessionsByPID = Dictionary(sample.roster.sessions.map { ($0.pid, $0) },
                                       uniquingKeysWith: { a, _ in a })

        let agents = snapshot.sessions.map { group -> PanelData.AgentRow in
            let session = group.sessionPID.flatMap { sessionsByPID[$0] }
            let cwd = session?.cwd
            let git = cwd.flatMap(GitLocation.find(from:))
            let base = git?.root ?? cwd

            let title = git?.repo ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? group.label
            var subtitle: String?
            if let git, let branch = git.branch, !git.isDefaultBranch {
                subtitle = branch
            } else if let prompt = session?.promptPreview, !prompt.isEmpty {
                subtitle = "“\(prompt)”"
            }

            let paths = pathLines(pids: group.pids, byPID: byPID, cpu: cpu, base: base)
            let detail = detailLine(group: group, hottest: paths.first, base: base)
            let app = group.sessionPID.flatMap { hostApp(of: $0, byPID: byPID, bundles: bundles) }

            return PanelData.AgentRow(id: "\(group.key)", title: title, subtitle: subtitle,
                                      detail: detail, cpu: group.cpuPercent,
                                      rss: group.rssBytes, appBundle: app,
                                      folder: base, paths: paths)
        }

        let leftovers = snapshot.orphans.map { group -> PanelData.LeftoverRow in
            var title = group.label
            if case let .orphan(repo, worktree) = group.key, !repo.isEmpty {
                title = "\(repo) · \(worktree)"
            } else {
                // No worktree to name it after: say where its processes run instead of a
                // session number nobody remembers.
                let lines = pathLines(pids: group.pids, byPID: byPID, cpu: cpu, base: nil)
                if let first = lines.first(where: { !$0.path.isEmpty && $0.path != "/" }) {
                    title = first.display
                } else if let names = group.breakdown.first?.name {
                    title = names
                }
            }
            let names = group.breakdown.prefix(3).map {
                $0.count > 1 ? "\($0.count)× \($0.name)" : $0.name
            }.joined(separator: ", ")
            return PanelData.LeftoverRow(
                id: "\(group.key)", key: group.key, title: title,
                detail: names.isEmpty ? (group.containerIDs.isEmpty ? nil : "containers only") : names,
                cpu: group.cpuPercent, rss: group.rssBytes,
                containers: group.containerIDs.count,
                age: group.oldestProcessStartedAt.map { machine.capturedAt.timeIntervalSince($0) })
        }

        let apps = appRows(groups: snapshot.everythingElse, byPID: byPID, cpu: cpu,
                           bundles: bundles)

        return PanelData(header: header, agents: agents, leftovers: leftovers, apps: apps,
                         canStop: sample.roster.allowsReaping)
    }

    /// The group's processes bucketed by working directory, hottest first.
    private static func pathLines(pids: [Int32], byPID: [Int32: ProcessSample],
                                  cpu: [Int32: Double], base: String?) -> [PanelData.PathLine] {
        var buckets: [String: (cpu: Double, rss: UInt64, names: [String: Int])] = [:]
        for pid in pids {
            guard let process = byPID[pid] else { continue }
            let path = ProcInfo.cwd(pid) ?? ""
            var bucket = buckets[path] ?? (0, 0, [:])
            bucket.cpu += cpu[pid] ?? 0
            bucket.rss += process.rssBytes
            bucket.names[AttributionEngine.processName(of: process), default: 0] += 1
            buckets[path] = bucket
        }
        return buckets.map { path, bucket in
            let names = bucket.names.sorted { $0.value > $1.value }.prefix(3).map {
                $0.value > 1 ? "\($0.value)× \($0.key)" : $0.key
            }.joined(separator: ", ")
            let display: String
            if path.isEmpty { display = "unknown folder" }
            else if path == base { display = "." }
            else { display = PathFormat.short(path, relativeTo: base) }
            return PanelData.PathLine(path: path, display: display, cpu: bucket.cpu,
                                      rss: bucket.rss, names: names)
        }
        .sorted { $0.cpu > $1.cpu }
    }

    /// "apps/front-v2 · 4× vitest": where the heat is and what is making it.
    private static func detailLine(group: AttributionGroup, hottest: PanelData.PathLine?,
                                   base: String?) -> String? {
        let kinds = group.breakdown.filter { ($0.cpuPercent ?? 0) >= 1 }.prefix(2)
        let what = (kinds.isEmpty ? Array(group.breakdown.prefix(1)) : Array(kinds)).map {
            $0.count > 1 ? "\($0.count)× \($0.name)" : $0.name
        }.joined(separator: ", ")
        var parts: [String] = []
        if let hottest, hottest.cpu >= 1, hottest.display != ".", !hottest.path.isEmpty {
            parts.append(hottest.display)
        }
        if !what.isEmpty { parts.append(what) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The app a session runs inside (T3 Code, Ghostty, Terminal, the Claude app), found by
    /// walking up the process tree to the first ancestor that lives in an `.app` bundle.
    private static func hostApp(of pid: Int32, byPID: [Int32: ProcessSample],
                                bundles: BundleCache) -> String? {
        var current = byPID[pid]
        for _ in 0..<24 {
            guard let process = current, process.pid > 1 else { return nil }
            if let bundle = bundles.lookup(process).bundle { return bundle }
            current = byPID[process.ppid]
        }
        return nil
    }

    /// Everything outside agent sessions, regrouped by the app each process belongs to,
    /// so "Other processes 91%" becomes T3 Code, Slack, WindowServer and so on.
    private static func appRows(groups: [AttributionGroup], byPID: [Int32: ProcessSample],
                                cpu: [Int32: Double], bundles: BundleCache) -> [PanelData.AppRow] {
        var buckets: [String: (name: String, bundle: String?, cpu: Double, rss: UInt64, count: Int)] = [:]
        for group in groups {
            for pid in group.pids {
                guard let process = byPID[pid] else { continue }
                let found = bundles.lookup(process)
                let key: String
                let name: String
                if let bundle = found.bundle {
                    key = bundle
                    name = URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
                } else {
                    name = readable(AttributionEngine.processName(of: process))
                    key = "proc:" + name
                }
                var bucket = buckets[key] ?? (name, found.bundle, 0, 0, 0)
                bucket.cpu += cpu[pid] ?? 0
                bucket.rss += process.rssBytes
                bucket.count += 1
                buckets[key] = bucket
            }
        }
        return buckets.map { key, b in
            PanelData.AppRow(id: key, name: b.name, appBundle: b.bundle, cpu: b.cpu,
                             rss: b.rss, count: b.count)
        }
        .sorted { $0.cpu == $1.cpu ? $0.rss > $1.rss : $0.cpu > $1.cpu }
    }

    /// `com.apple.Virtualization.VirtualMachine` reads as `VirtualMachine`.
    private static func readable(_ name: String) -> String {
        let parts = name.split(separator: ".")
        guard parts.count >= 3, !name.contains(" "), parts.first.map({ $0.count <= 4 }) == true
        else { return name }
        return String(parts.last!)
    }
}
