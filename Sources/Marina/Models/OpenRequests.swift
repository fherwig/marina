import AppKit

/// `open -a Marina <folder>` from another app, a script or Finder.
///
/// Two awkward moments are what this exists for. At launch the request arrives
/// before any window has an AppState, so it has to wait rather than be
/// dropped; and with several windows open, the right one is whichever already
/// shows that folder, not whichever happens to be in front.
@MainActor
final class OpenRequests {
    static let shared = OpenRequests()

    private var pending: [URL] = []

    private init() {}

    func receive(_ urls: [URL]) {
        DebugLog.open("asked to open \(urls.map(\.path).joined(separator: ", "))")
        pending.append(contentsOf: urls)
        deliver()
    }

    /// Called again whenever a window registers: at launch the first request
    /// lands before there is anywhere to put it.
    func deliver() {
        guard !pending.isEmpty else { return }
        guard MarinaWindows.shared.current != nil else {
            DebugLog.open("no window yet — holding \(pending.count)")
            return
        }
        let urls = pending
        pending = []
        for url in urls { open(url) }
    }

    private func raise(_ host: AppState) { Self.raiseWindow(of: host) }

    private static func raiseWindow(of host: AppState) {
        guard NSApp.isActive else { return }
        MarinaWindows.shared.window(for: host)?.makeKeyAndOrderFront(nil)
    }

    private func open(_ url: URL) {
        let resolved = PaneState.resolved(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            DebugLog.open("no such path: \(resolved.path)")
            return
        }
        // a file was passed: show the folder it is in, with it selected
        let folder = isDirectory.boolValue ? resolved : resolved.deletingLastPathComponent()
        let select = isDirectory.boolValue ? nil : resolved

        // a window already showing that folder wins over the front one
        let host = MarinaWindows.shared.all.first { $0.hasTab(at: folder) }
            ?? MarinaWindows.shared.current
        guard let host else { return }
        host.show(folder: folder, selecting: select)
        // Whether Marina comes to the front is the caller's business, not
        // ours: `open -a Marina x` activates it through LaunchServices and
        // `open -g -a Marina x` deliberately does not. So raise the window
        // only once the app is actually active — and again a moment later,
        // because the request can arrive before the activation does.
        raise(host)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak host] in
            MainActor.assumeIsolated { if let host { Self.raiseWindow(of: host) } }
        }
        DebugLog.open("opened \(folder.path)\(select.map { " selecting \($0.lastPathComponent)" } ?? "")")
    }
}
