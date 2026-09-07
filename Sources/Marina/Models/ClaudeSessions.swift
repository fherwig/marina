import Foundation
import Combine

/// A running Claude Code session, and the directory it is working in.
struct ClaudeSession: Identifiable, Hashable {
    let pid: Int32
    let directory: URL
    /// The tmux session it belongs to, or nil when it was started straight from
    /// a terminal window.
    let tmuxSession: String?

    var id: Int32 { pid }
    var isBare: Bool { tmuxSession == nil }

    var name: String {
        let last = directory.lastPathComponent
        return last.isEmpty ? directory.path : last
    }

    /// Worth showing next to the folder name only when it says something the
    /// folder name does not.
    var caption: String? {
        guard let tmuxSession, tmuxSession != name else { return nil }
        return tmuxSession
    }
}

/// One scan for the whole app, shared by every window — the same arrangement as
/// FavouritesStore, and for the same reason. Rescanning is deliberate: the list
/// is a snapshot taken when asked for, not a live feed.
@MainActor
final class ClaudeSessionsStore: ObservableObject {
    static let shared = ClaudeSessionsStore()

    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date?

    private init() {}

    func refresh() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .userInitiated) {
            let found = ClaudeSessionScan.sessions()
            await MainActor.run { [weak self] in
                self?.sessions = found
                self?.scanning = false
                self?.lastScan = Date()
            }
        }
    }

    /// The first look, once per launch — so the section is not empty before
    /// anyone has pressed the button.
    func refreshIfNeeded() {
        guard lastScan == nil, !scanning else { return }
        refresh()
    }
}

/// Finds the running Claude sessions by reading the process table.
///
/// Matching is on argv[0]'s basename, which is `claude` for the shim and a bare
/// version number for newer builds that exec the versioned binary directly —
/// `pgrep -x claude` misses those entirely, so it is not used. Each match's
/// ancestry is then walked: reaching a tmux pane makes it that session's and
/// the pane's own path is the answer; reaching launchd instead means it was
/// started bare from a terminal, and its cwd comes from lsof.
enum ClaudeSessionScan {
    private struct Row {
        let pid: Int32
        let ppid: Int32
        let tty: String
        let args: String
    }

    private static let ps = "/bin/ps"
    private static let lsof = "/usr/sbin/lsof"
    private static let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    static func sessions() -> [ClaudeSession] {
        let rows = processTable()
        guard !rows.isEmpty else { return [] }

        let panes = tmuxPanes()
        let paneIDs = Set(panes.keys)
        var parents: [Int32: Int32] = [:]
        for row in rows { parents[row.pid] = row.ppid }

        let claudes = rows.filter(isSession)
        var pane: [Int32: Int32] = [:]
        var bare: [Int32] = []
        for row in claudes {
            if let owner = owningPane(row.pid, parents: parents, panes: paneIDs) {
                pane[row.pid] = owner
            } else {
                bare.append(row.pid)
            }
        }
        let cwds = workingDirectories(of: bare)

        var found: [ClaudeSession] = []
        for row in claudes {
            let path: String?
            let session: String?
            if let owner = pane[row.pid], let info = panes[owner] {
                path = info.path
                session = info.session
            } else {
                path = cwds[row.pid]
                session = nil
            }
            guard let path, !path.isEmpty else { continue }
            found.append(ClaudeSession(pid: row.pid,
                                       directory: URL(fileURLWithPath: path).standardizedFileURL,
                                       tmuxSession: session))
        }

        // One row per directory: two sessions in the same folder are still one
        // place to go, and a named tmux session is the more useful of the two.
        var byPath: [String: ClaudeSession] = [:]
        for session in found {
            if let existing = byPath[session.directory.path], existing.tmuxSession != nil { continue }
            byPath[session.directory.path] = session
        }
        return byPath.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Process table

    private static func processTable() -> [Row] {
        // trailing '=' on each column suppresses the header; args goes last
        // because it is the one field that contains spaces
        let out = capture(ps, ["-u", NSUserName(), "-o", "pid=,ppid=,tty=,args="])
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { return nil }
            return Row(pid: pid, ppid: ppid, tty: String(f[2]), args: String(f[3]))
        }
    }

    private static func isSession(_ row: Row) -> Bool {
        // no controlling terminal means the daemon and its helpers, not a session
        guard row.tty != "??" else { return false }
        let words = row.args.split(separator: " ")
        guard let argv0 = words.first else { return false }
        let base = (String(argv0) as NSString).lastPathComponent
        guard base == "claude" || isVersion(base) else { return false }
        let subcommand = words.dropFirst().first.map(String.init) ?? ""
        return !["daemon", "bg-pty-host", "bg-spare"].contains(subcommand)
    }

    /// "2.1.260" and the like — what newer installs use as the binary name.
    private static func isVersion(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// The nearest ancestor that is a tmux pane, starting with the process
    /// itself — a pane running claude directly is its own pane_pid.
    private static func owningPane(_ pid: Int32, parents: [Int32: Int32], panes: Set<Int32>) -> Int32? {
        var current = pid
        for _ in 0..<64 {
            if panes.contains(current) { return current }
            guard let parent = parents[current], parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    // MARK: - tmux

    private static func tmuxPanes() -> [Int32: (session: String, path: String)] {
        guard let tmux = tmuxPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return [:]
        }
        let out = capture(tmux, ["list-panes", "-a", "-F", "#{pane_pid}\t#{session_name}\t#{pane_current_path}"])
        var panes: [Int32: (session: String, path: String)] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 3, let pid = Int32(f[0]) else { continue }
            panes[pid] = (session: String(f[1]), path: String(f[2]))
        }
        return panes
    }

    // MARK: - Working directories

    private static func workingDirectories(of pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let out = capture(lsof, ["-a", "-d", "cwd", "-Fn", "-p", pids.map(String.init).joined(separator: ",")])
        var dirs: [Int32: String] = [:]
        var pid: Int32?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid {
                dirs[pid] = String(line.dropFirst())
            }
        }
        return dirs
    }

    // MARK: - Running things

    private static func capture(_ path: String, _ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return "" }
        // drain before waiting: a full pipe would deadlock the child
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
