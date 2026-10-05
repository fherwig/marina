import SwiftUI
import AppKit

@main
struct MarinaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Marina", id: "main") {
            RootView()
        }
        .defaultSize(width: 1150, height: 720)
        .commands { MarinaCommands() }
    }
}

/// One AppState per window — tabs, panes and shells belong to their window, so
/// ⌥⌘N gives you a genuinely separate Marina rather than a mirror of this one.
struct RootView: View {
    @StateObject private var app = AppState()

    var body: some View {
        ContentView()
            .environmentObject(app)
            .frame(minWidth: 720, minHeight: 420)
            // how the menu commands find the window they belong to
            .background(WindowAccessor { window in
                MarinaWindows.shared.register(app, window: window)
            })
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminalKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Marina has its own tabs; native window tabs would stack a second
        // Marina inside the first one, which is exactly not the point.
        NSWindow.allowsAutomaticWindowTabbing = false
        watchTerminalKey()
    }

    /// `open -a Marina <folder>`, Finder's "Open With", a drop on the Dock
    /// icon. Declared in Info.plist as a Viewer of public.folder, with
    /// LSHandlerRank Alternate: Marina opens a folder when asked, without
    /// putting itself forward to replace Finder as the handler for every
    /// double-clicked folder.
    func application(_ application: NSApplication, open urls: [URL]) {
        OpenRequests.shared.receive(urls)
    }

    /// The menu item carries the terminal shortcut as a character, and on a
    /// German keyboard that character is a **dead key** (^): it prints nothing
    /// on its own, so the menu equivalent may never match. Catch the key by
    /// position instead. Swallowing the event keeps this and the menu item from
    /// both firing — whichever of the two sees it first, exactly one acts.
    private func watchTerminalKey() {
        terminalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard KeyboardLayout.terminalKeyCodes.contains(event.keyCode),
                  modifiers == [.command] || modifiers == [.command, .option] else {
                return event
            }
            // the NSEvent stays out of the isolated block: it is not Sendable
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let app = MarinaWindows.shared.current else { return false }
                if modifiers.contains(.option) {
                    app.toggleTerminalMax()
                } else {
                    app.toggleTerminal()
                }
                return true
            }
            return handled ? nil : event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
