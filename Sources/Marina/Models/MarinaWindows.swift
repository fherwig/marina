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
        // Space's Quick Look panel looks for its controller in the key
        // window's responder chain — see QuickLookResponder
        QuickLookResponder.install(in: window)
        GuideShots.begin(state, window: window)     // nothing unless --guide-shots
        if states[key] === state { return }
        states[key] = state
        order.removeAll { $0 === state }
        order.append(state)
        // an `open -a Marina <folder>` at launch arrives before any window
        // exists; now there is one
        OpenRequests.shared.deliver()
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak state] _ in
            MainActor.assumeIsolated {
                // the window's tabs go with it, and so must their shells: a
                // terminal whose tab is gone is unreachable, but its processes
                // keep running under Marina
                state?.shutdownAllTabs()
                MarinaWindows.shared.states[key] = nil
                MarinaWindows.shared.order.removeAll { $0 === state }
            }
        }
    }

    /// After a change to the disk: every pane, in every tab of every window,
    /// since a move empties one folder and fills another and both may be on
    /// screen anywhere.
    func reloadAllPanes() {
        for state in order {
            for tab in state.tabs { tab.panes.forEach { $0.reload() } }
        }
    }

    /// Every open window's state, most recently registered last.
    var all: [AppState] { order }

    func window(for state: AppState) -> NSWindow? {
        for (key, value) in states where value === state {
            return NSApp.windows.first { ObjectIdentifier($0) == key }
        }
        return nil
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
