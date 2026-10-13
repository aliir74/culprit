import Darwin
import Foundation

/// The two per-process facts the engine does not keep: the kernel's view of a process's
/// working directory (its `PWD` variable can be stale or absent), and its executable path.
enum ProcInfo {
    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty ? nil : path
    }

    /// When the kernel started this pid, or nil if no such process. Paired with a pid it
    /// identifies one process: a recycled pid has a different start time.
    static func startTime(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                    + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The outermost `.app` bundle an executable lives in. Helpers nest bundles inside
    /// their parent app (`T3 Code.app/Contents/Frameworks/T3 Code Helper.app/...`), and the
    /// parent is the one a person recognises.
    static func appBundle(ofExecutable path: String) -> String? {
        guard let range = path.range(of: ".app/") else {
            return path.hasSuffix(".app") ? path : nil
        }
        return String(path[..<range.lowerBound]) + ".app"
    }
}

/// Repo and branch for a directory, read straight from `.git` without spawning git.
struct GitLocation: Sendable {
    let root: String
    /// The main repository's folder name, also for a linked worktree, whose own folder is
    /// usually a generated id like `t3-c7787851`.
    let repo: String
    let branch: String?
    let isLinkedWorktree: Bool

    static func find(from directory: String) -> GitLocation? {
        let fm = FileManager.default
        var url = URL(fileURLWithPath: directory)
        for _ in 0..<16 {
            let git = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return GitLocation(root: url.path, repo: url.lastPathComponent,
                                       branch: branch(headAt: git.path + "/HEAD"),
                                       isLinkedWorktree: false)
                }
                // A linked worktree: `.git` is a file pointing at
                // <main>/.git/worktrees/<name>.
                guard let text = try? String(contentsOf: git, encoding: .utf8),
                      let marker = text.range(of: "gitdir:") else { return nil }
                var gitDir = text[marker.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !gitDir.hasPrefix("/") {
                    gitDir = url.appendingPathComponent(gitDir).standardized.path
                }
                let repo: String
                if let r = gitDir.range(of: "/.git/worktrees/") {
                    repo = URL(fileURLWithPath: String(gitDir[..<r.lowerBound])).lastPathComponent
                } else {
                    repo = url.lastPathComponent
                }
                return GitLocation(root: url.path, repo: repo,
                                   branch: branch(headAt: gitDir + "/HEAD"),
                                   isLinkedWorktree: true)
            }
            if url.path == "/" { break }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func branch(headAt path: String) -> String? {
        guard let head = try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let prefix = "ref: refs/heads/"
        return head.hasPrefix(prefix) ? String(head.dropFirst(prefix.count)) : String(head.prefix(7))
    }

    var isDefaultBranch: Bool { branch == "main" || branch == "master" }
}

enum PathFormat {
    static let home = NSHomeDirectory()

    /// `apps/front-v2` when inside `base`, `~/…` otherwise, last three components at most.
    static func short(_ path: String, relativeTo base: String? = nil) -> String {
        if let base, path.hasPrefix(base + "/") {
            return String(path.dropFirst(base.count + 1))
        }
        var display = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let parts = display.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count > 4 {
            display = "…/" + parts.suffix(3).joined(separator: "/")
        }
        return display
    }
}
