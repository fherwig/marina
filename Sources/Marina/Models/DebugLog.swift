import Foundation

/// Opt-in tracing for the two cwd syncs, which are timing-dependent enough
/// that reading the code has twice pointed at the wrong cause. Turn on with
///   defaults write org.fherwig.marina marina.debugFollow -bool true
/// and watch /tmp/marina-follow.log.
///
/// The flag is read per call, not cached: a cached one needs a relaunch to
/// take effect, and a relaunch is exactly what throws away the state that was
/// being investigated.
enum DebugLog {
    static let path = "/tmp/marina-follow.log"

    static var followEnabled: Bool {
        UserDefaults.standard.bool(forKey: "marina.debugFollow")
    }

    /// Requests from other apps (`open -a Marina <folder>`), which are hard to
    /// watch any other way: they arrive before there is a window, from a
    /// process that is not Marina.
    ///   defaults write org.fherwig.marina marina.debugOpen -bool true
    static func open(_ text: @autoclosure () -> String) {
        guard UserDefaults.standard.bool(forKey: "marina.debugOpen") else { return }
        write("open: " + text())
    }

    static func follow(_ text: @autoclosure () -> String) {
        guard followEnabled else { return }
        write(text())
    }

    private static func write(_ text: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        guard let data = "\(stamp)  \(text)\n".data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
