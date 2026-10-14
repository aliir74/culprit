import Darwin
import Foundation

/// One process Culprit stopped, pinned to its start time so a recycled pid is never
/// mistaken for it.
struct PausedProcess: Codable, Hashable, Sendable {
    let pid: Int32
    let startedAt: Date

    /// Still the process that was paused: same pid, same start time. Both sides come from
    /// the kernel's microsecond start time, so the margin only absorbs rounding.
    var isSame: Bool {
        guard let now = ProcInfo.startTime(pid) else { return false }
        return abs(now.timeIntervalSince(startedAt)) < 0.001
    }
}

/// The pauses Culprit holds, kept on disk so that a crash or a `kill -9` cannot leave a
/// session frozen: the next launch resumes whatever is still recorded here.
enum PauseStore {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask)[0]
        .appendingPathComponent("Culprit/paused.json")

    /// Row id to the processes paused under it.
    static func load() -> [String: [PausedProcess]] {
        guard let data = try? Data(contentsOf: url),
              let paused = try? JSONDecoder().decode([String: [PausedProcess]].self, from: data)
        else { return [:] }
        return paused
    }

    /// False when the record could not be written. A pause must not go ahead without one.
    @discardableResult
    static func save(_ paused: [String: [PausedProcess]]) -> Bool {
        let fm = FileManager.default
        guard !paused.isEmpty else {
            try? fm.removeItem(at: url)
            return !fm.fileExists(atPath: url.path)
        }
        do {
            let data = try JSONEncoder().encode(paused)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Sends `SIGCONT` to each process that is still the one recorded, in the order given.
    @discardableResult
    static func resume(_ processes: [PausedProcess]) -> Int {
        processes.filter { $0.isSame && kill($0.pid, SIGCONT) == 0 }.count
    }

    /// Resumes everything on disk and clears it. Run at launch, before anything else
    /// could pause, to undo what a previous run left behind.
    static func recover() {
        let leftover = load()
        guard !leftover.isEmpty else { return }
        for processes in leftover.values { resume(processes.reversed()) }
        save([:])
    }
}
