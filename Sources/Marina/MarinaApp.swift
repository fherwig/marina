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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Marina has its own tabs; native window tabs would stack a second
        // Marina inside the first one, which is exactly not the point.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
