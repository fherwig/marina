import AppKit

/// Handing a file, folder or link to macOS to open, without waiting for it.
///
/// `NSWorkspace.open(_:)` returns only once LaunchServices has answered, and
/// once it never did: Marina froze with its main thread in that call, waiting
/// on an XPC reply, after Go ▸ Open (⌘O) opened a file in a pane (sampled
/// 2026-10-18; Force Quit took its two terminals with it). The form with a
/// completion handler hands the request over and returns at once, so a
/// LaunchServices that is slow or stuck holds up that one file, not Marina.
enum Opening {
    static func open(_ url: URL) {
        open(firstOf: [url])
    }

    /// Each tried in turn until one opens; for a link whose form changed
    /// between macOS versions.
    static func open(firstOf urls: [URL]) {
        guard let url = urls.first else { return }
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            // as before, a file nothing opens is macOS's to say
            guard error != nil, urls.count > 1 else { return }
            DispatchQueue.main.async { open(firstOf: Array(urls.dropFirst())) }
        }
    }
}
