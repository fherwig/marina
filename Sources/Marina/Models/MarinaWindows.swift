import AppKit
import SwiftUI

/// Which window the menu bar acts on.
///
/// Each Marina window owns its own `AppState` (tabs, panes, shells), so the
/// commands have to find the state of the window that has the keyboard.
/// SwiftUI's `focusedSceneValue` is the idiomatic route but it reports nil
/// whenever no SwiftUI view inside the window holds focus — which includes the
/// case that matters most here, the terminal, an AppKit view. So the lookup
/// goes through AppKit's key window, which is always right.
@MainActor
final class MarinaWindows {
    static let shared = MarinaWindows()

    private var states: [ObjectIdentifier: AppState] = [:]
    /// most recently registered last — the fallback when there is no key
    /// window (the app is in the background, e.g. under UI test automation)
    private var order: [AppState] = []

    func register(_ state: AppState, window: NSWindow) {
        let key = ObjectIdentifier(window)
        if states[key] === state { return }
        states[key] = state
        order.removeAll { $0 === state }
        order.append(state)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak state] _ in
            MainActor.assumeIsolated {
                MarinaWindows.shared.states[key] = nil
                MarinaWindows.shared.order.removeAll { $0 === state }
            }
        }
    }

    var current: AppState? {
        var window = NSApp.keyWindow ?? NSApp.mainWindow
        // a rename sheet is the key window; the commands belong to its parent
        while let parent = window?.sheetParent { window = parent }
        if let window, let state = states[ObjectIdentifier(window)] { return state }
        return order.last
    }
}

/// Hands back the NSWindow a SwiftUI view landed in.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { report(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { report(nsView) }
    }

    private func report(_ view: NSView) {
        guard let window = view.window else { return }
        onWindow(window)
    }
}
