import SwiftUI
import AppKit
import QuickLookUI

@main
struct MarinaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // guide mode stages its sidebar before the first view is built
        if GuideShots.isActive { GuideShots.prepare() }
    }

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

    /// `open -a Marina <path>` while Marina was running made a NEW, empty
    /// window at the home folder and put the path in a tab of the window
    /// behind it (2026-10-15: "it will open a new marina window but not switch
    /// the file"). AppKit hands the open-documents event to SwiftUI, and
    /// SwiftUI answers it with a window of its WindowGroup whatever
    /// application(_:open:) then does with the URLs; neither
    /// handlesExternalEvents setting stops that for a file. Taking the event
    /// here, before SwiftUI sees it, leaves the routing to OpenRequests. This
    /// is the documented place: AppKit's own handlers are installed by now.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(openDocuments(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
    }

    @objc private func openDocuments(_ event: NSAppleEventDescriptor,
                                     withReply reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        // one path arrives as a single descriptor, several as a list (1-based)
        let items = list.numberOfItems == 0
            ? [list] : (1...list.numberOfItems).compactMap { list.atIndex($0) }
        let urls = items.compactMap(\.fileURLValue)
        MainActor.assumeIsolated { OpenRequests.shared.receive(urls) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if GuideShots.isActive {
            // photographing itself: stay in the background, take no keyboard
            NSApp.setActivationPolicy(.accessory)
            NSWindow.allowsAutomaticWindowTabbing = false
            DispatchQueue.main.async { GuideShots.openWindow() }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Marina has its own tabs; native window tabs would stack a second
        // Marina inside the first one, which is exactly not the point.
        NSWindow.allowsAutomaticWindowTabbing = false
        watchTerminalKey()
        // a request that launched Marina may still be waiting for a window
        DispatchQueue.main.async {
            MainActor.assumeIsolated { OpenRequests.shared.launchFinished() }
        }
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

    // MARK: - Quick Look

    // The Quick Look panel walks the responder chain for an object willing to
    // control it; the app delegate is at the end of every window's chain, so
    // answering here covers every pane in every window. QuickLook.shared then
    // supplies the files and takes the arrow keys the panel passes on.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    // AppKit calls these on the main thread; the annotation cannot say so
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLook.shared
            panel.delegate = QuickLook.shared
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}
