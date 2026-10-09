import AppKit
import ScreenCaptureKit
import SwiftUI

/// `Marina --guide-shots <folder>` photographs Marina for docs/user-guide.md.
///
/// The guide's pictures have to be true of the released app, and they must not
/// show a real person's machine: no real Claude sessions, disks, account names,
/// home folder or shell prompt. So the app takes them of itself, in a staged
/// world — the book's own example folders `letters` and `notes`, put in place by
/// Support/guide/make-shots.sh — with invented sidebar entries, and quits.
///
/// It photographs its own window through ScreenCaptureKit's current-process
/// content (macOS 14.4), which needs no screen-recording permission — measured
/// with a process that has none, its window off screen. That is the window
/// server's picture, so macOS 26's glass sidebar and toolbar come out as they
/// look; drawing the window into an image itself (cacheDisplay) left the
/// sidebar blank and the toolbar as white blobs. The window stays off screen
/// and the app in the background, so it never takes the keyboard from whoever
/// is at the machine — which is also why its text is drawn in the slightly
/// greyed inactive style. Run it as the isolated copy, never as Marina itself:
/// it rewrites the favourites.
///
/// Its terminals use a shell whose start-up files are staged by make-shots.sh
/// (ZDOTDIR), so the prompt shows the folder and nothing else: no user name,
/// no host, nothing from the real profile.
@MainActor
enum GuideShots {
    nonisolated static let output: URL? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--guide-shots"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }()

    nonisolated static var isActive: Bool { output != nil }

    private static var started = false
    private static let documents = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents")
    private static var letters: URL { documents.appendingPathComponent("letters") }
    private static var notes: URL { documents.appendingPathComponent("notes") }

    /// Before any view exists: the invented sidebar, so nothing real is ever
    /// drawn, not even for a frame.
    /// The staged start-up files for the shell; see TerminalSession.
    nonisolated static var shellStartupFolder: String? {
        isActive ? "/tmp/marina-guide/zdotdir" : nil
    }

    /// Runs from MarinaApp.init, BEFORE the application object exists — NSApp
    /// is nil here, so nothing in this function may touch it (light mode is
    /// set in the launch callback instead).
    static func prepare() {
        ClaudeSessionsStore.shared.stage([
            ClaudeSession(pid: 41001, directory: letters, tmuxSession: nil),
            ClaudeSession(pid: 41002, directory: notes, tmuxSession: nil),
        ])
        VolumesStore.shared.stage([])
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "marina.volumesSectionCollapsed")
        defaults.set(false, forKey: "marina.claudeSectionCollapsed")
        defaults.set(false, forKey: "marina.terminalLeftOnly")
        // the Favourites a new user starts with, left as they are, and the
        // course's two folders in a section of their own
        let store = FavouritesStore.shared
        let course = store.addSection(named: "Course")
        store.add(letters, toSection: course)
        store.add(notes, toSection: course)
    }

    private static var window: NSWindow?

    /// Guide mode opens its own window, hosting exactly the view the app's
    /// normal window hosts (RootView), with the toolbar and title bridged into
    /// the window's chrome. Waiting for SwiftUI's own first window did not work
    /// for an app started in the background: the process sat in its run loop
    /// with no window at all (measured, started directly and through
    /// LaunchServices alike), while the very first run had happened to get one.
    static func openWindow() {
        let hosting = NSHostingView(rootView: RootView())
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let made = NSWindow(contentRect: NSRect(x: -14000, y: 200, width: 1240, height: 780),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                        .fullSizeContentView],
                            backing: .buffered, defer: false)
        made.title = "Marina"
        made.toolbarStyle = .unified
        made.contentView = hosting
        made.setFrame(NSRect(x: -14000, y: 200, width: 1240, height: 780), display: true)
        made.orderBack(nil)            // in the window server, so it can be photographed
        window = made
        note("window opened")
    }

    /// The first window: put it off screen at a fixed size, then work through
    /// the shots.
    static func begin(_ app: AppState, window: NSWindow) {
        guard isActive, !started, let output else { return }
        started = true
        note("first window registered")
        // light mode, the book being printed on white — set here, on the
        // window and the app, once the window exists: set in the launch
        // callback, SwiftUI never created the window at all (measured)
        NSApp.appearance = NSAppearance(named: .aqua)
        window.appearance = NSAppearance(named: .aqua)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        window.setFrame(NSRect(x: -14000, y: 200, width: 1240, height: 780), display: true)
        Task { @MainActor in
            await shoot(app, window: window, into: output)
            NSApp.terminate(nil)
        }
    }

    /// Progress, to the log make-shots.sh keeps (/tmp/marina-guide.log).
    private static func note(_ text: String) {
        FileHandle.standardError.write(Data("guide: \(text)\n".utf8))
    }

    /// How a tab is set up for a picture. The terminal does not follow the
    /// pane: following types `cd` with the full path, and the full path holds
    /// the user's name. A third of the window for the terminal, as a drag on
    /// its divider would give, leaves room for the file list.
    private static func arrange(_ tab: TabState?) {
        tab?.followPanes = false
        tab?.terminalHeight = 300
    }

    /// The viewer pictures put the terminal under the left pane only (⌥⌘J), so
    /// the viewer has the full height.
    private static func terminalLeftOnly(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "marina.terminalLeftOnly")
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private static func shoot(_ app: AppState, window: NSWindow, into dir: URL) async {
        await pause(1.0)

        // ── One session: letters, its terminal, its folder ──────────────────
        // the folder first, and only then the terminal, which starts in it:
        // opened the other way round, the shell is sent a `cd` with the full
        // path — the user's name in the picture
        arrange(app.activeTab)
        app.activeTab?.activePane.navigate(to: letters)
        await pause(1.0)
        app.activeTab?.toggleTerminal()
        await pause(3.0)
        app.activeTab?.terminal?.send("claude")   // typed, not run
        app.activeTab?.activePane.select(letters.appendingPathComponent("thank-you.md"))
        await pause(1.0)
        await capture(window, to: dir.appendingPathComponent("01-one-session.png"))

        // ── The context file, rendered in the viewer ────────────────────────
        app.activeTab?.activePane.select(letters.appendingPathComponent("CLAUDE.md"))
        terminalLeftOnly(true)
        app.activeTab?.toggleViewer()
        await pause(5.0)                       // WebKit, on a busy machine
        await capture(window, to: dir.appendingPathComponent("02-context-file.png"))
        app.activeTab?.toggleViewer()
        terminalLeftOnly(false)

        // ── notes: hidden files shown, drafts and old ───────────────────────
        app.newTab(at: notes)
        await pause(1.0)
        arrange(app.activeTab)
        if let tab = app.activeTab {
            tab.activePane.showHidden = true
            tab.activePane.select(notes.appendingPathComponent(".claude"))
            tab.toggleTerminal()
            await pause(3.0)
        }
        await capture(window, to: dir.appendingPathComponent("03-notes-hidden.png"))

        // ── the settings file, inside .claude ───────────────────────────────
        if let tab = app.activeTab {
            let claude = notes.appendingPathComponent(".claude")
            tab.activePane.navigate(to: claude)
            tab.activePane.select(claude.appendingPathComponent("settings.local.json"))
            terminalLeftOnly(true)
            tab.toggleViewer()
            await pause(5.0)
        }
        await capture(window, to: dir.appendingPathComponent("04-settings-file.png"))
        app.activeTab?.toggleViewer()
        terminalLeftOnly(false)
        app.activeTab?.activePane.navigate(to: notes)
        await pause(0.8)

        // ── several sessions: tabs and the Claude Sessions section ──────────
        app.selectTab(0)
        await pause(1.0)
        await capture(window, to: dir.appendingPathComponent("05-several-sessions.png"))
    }

    // MARK: - Photographing the window

    private static func capture(_ window: NSWindow, to url: URL) async {
        guard #available(macOS 14.4, *) else { note("needs macOS 14.4"); return }
        note("capturing \(url.lastPathComponent)")
        do {
            let content = try await SCShareableContent.currentProcess
            guard let shown = content.windows.first(where: {
                $0.windowID == CGWindowID(window.windowNumber)
            }) else { note("window \(window.windowNumber) not among \(content.windows.count) own windows"); return }
            let config = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            config.width = Int(shown.frame.width * scale)
            config.height = Int(shown.frame.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: shown),
                configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            note("wrote \(url.lastPathComponent) (\(image.width)×\(image.height))")
        } catch {
            FileHandle.standardError.write(Data("guide shot \(url.lastPathComponent): \(error)\n".utf8))
        }
    }
}
