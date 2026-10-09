import Foundation
import AppKit
import Combine

/// The logical units the keyboard can be in. ⌘+arrow moves between them in
/// the direction they sit on screen; plain arrows move inside one.
enum FocusTarget: Hashable {
    case sidebar
    case tabBar
    case pane(UUID)
}

struct FocusRequest: Equatable {
    let target: FocusTarget
    let gen: Int
}

/// ⌥⌘O asking a particular pane to put its Open With menu on screen — the
/// pane owns the geometry the menu has to be anchored to, the menu bar does
/// not.
struct OpenWithRequest: Equatable {
    let pane: UUID
    let gen: Int
}

struct RenameRequest: Identifiable {
    let url: URL
    let currentName: String
    /// Set for a file that was just created: the sheet names it before it
    /// exists in earnest, and the file opens once it has its final name.
    var isNew = false
    var id: String { url.path }

    var headline: String {
        isNew ? "New Markdown File" : "Rename “\(currentName)”"
    }
    var confirmTitle: String { isNew ? "Create" : "Rename" }
}

/// Naming a favourites section — new one when `target` is nil, otherwise a
/// rename. Carries where the keyboard was so the sheet can hand it back.
/// Closing a tab whose terminal is busy asks first, the way a terminal window
/// does. Identified by the tab's id, not its index: the list shifts under a
/// dialog that is up while other tabs close.
struct CloseTabPrompt: Identifiable {
    let id = UUID()
    let tab: UUID
    let program: String
}

struct SectionPrompt: Identifiable {
    let id = UUID()
    var target: UUID?
    var name: String
    var returnTo: FocusTarget?

    var headline: String { target == nil ? "New Section" : "Rename Section" }
    var confirmTitle: String { target == nil ? "Create" : "Rename" }
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var tabs: [TabState] = []
    @Published var activeTabIndex = 0
    /// Shared by every window — see FavouritesStore.
    var favourites: [URL] { FavouritesStore.shared.items }
    /// The same favourites grouped into the user's own sections.
    var favouriteSections: [FavouriteSection] { FavouritesStore.shared.sections }
    /// Running Claude Code sessions — see ClaudeSessionsStore.
    var claudeSessions: [ClaudeSession] { ClaudeSessionsStore.shared.sessions }
    var claudeSessionsScanning: Bool { ClaudeSessionsStore.shared.scanning }
    /// Mounted volumes and cloud drives — see VolumesStore.
    var volumes: [Volume] { VolumesStore.shared.volumes }
    @Published var focusRequest: FocusRequest?
    /// Where the keyboard actually is (kept in sync by ContentView); the
    /// ⌘-arrow moves need it to know which unit they are leaving.
    @Published var focusedTarget: FocusTarget?
    /// True while the keyboard is "in" the tab strip. The strip is chrome that
    /// comes and goes, and a freshly inserted SwiftUI view does not reliably
    /// accept programmatic focus — so this mode owns its keys through an event
    /// monitor instead of relying on @FocusState landing.
    @Published private(set) var tabBarActive = false
    private var tabBarKeyMonitor: Any?
    private var tabBarClickMonitor: Any?
    @Published var renameTarget: RenameRequest?
    @Published var sectionPrompt: SectionPrompt?
    @Published var closeTabPrompt: CloseTabPrompt?
    @Published var openWithRequest: OpenWithRequest?
    private var openWithGen = 0
    @Published var errorMessage: String?
    @Published var sidebarVisible = true
    @Published var helpVisible = false

    private var focusGen = 0
    private var favouritesObserver: AnyCancellable?
    private var claudeObserver: AnyCancellable?
    private var volumesObserver: AnyCancellable?

    var activeTab: TabState? {
        tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex] : nil
    }

    var activePane: PaneState? { activeTab?.activePane }

    init() {
        // views read the favourites through this window's AppState, so pass the
        // shared store's changes on — that is what makes a favourite added in
        // one window appear in the others
        favouritesObserver = FavouritesStore.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        claudeObserver = ClaudeSessionsStore.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        volumesObserver = VolumesStore.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Every window starts at home. It used to reopen the last folder any pane
    /// had visited — which was whichever pane happened to move last, so Marina
    /// came up in Screenshots or a temp folder with no way to predict which.
    /// Home is the same every time, and the sidebar is one ⌘0 away from there.
    func bootstrap() {
        guard tabs.isEmpty else { return }
        newTab(at: FileManager.default.homeDirectoryForCurrentUser)
    }

    func requestFocus(_ target: FocusTarget) {
        // any focus move elsewhere leaves the tab strip
        if target != .tabBar { leaveTabBar(focusPane: false) }
        focusGen += 1
        focusRequest = FocusRequest(target: target, gen: focusGen)
    }

    func focusActivePane() {
        guard let tab = activeTab else { return }
        requestFocus(.pane(tab.activePane.id))
    }

    // MARK: - Moving between logical units (⌘ + arrow)

    /// The tab bar shows when it is useful: more than one tab, or the keyboard
    /// is in it (⌘↑ reveals it even for a single tab).
    var tabBarVisible: Bool { tabs.count > 1 || tabBarActive }

    private var paneHasFocus: Bool {
        if case .pane = focusedTarget { return true }
        return false
    }

    /// ⌘↑ — one unit up, in the visual sense: terminal → file pane → tab bar.
    /// Going up a *folder* is ← or ⌫, never a ⌘ key.
    func focusUp() {
        guard !tabBarActive else { return }  // already at the top
        // the terminal branch only when the terminal really has the keyboard:
        // a stale AppKit first responder must not eat the keypress
        if let tab = activeTab, tab.terminalHasFocus, !paneHasFocus {
            tab.leaveTerminal()
            return
        }
        enterTabBar()
    }

    /// ⌘↓ — one unit down: tab bar → file pane → terminal.
    func focusDown() {
        if tabBarActive {
            leaveTabBar(focusPane: true)
            return
        }
        activeTab?.enterTerminal()
    }

    // MARK: - Tab strip as a keyboard unit

    func enterTabBar() {
        guard !tabs.isEmpty, !tabBarActive else { return }
        tabBarActive = true
        // clears the file pane's focus ring; the strip takes SwiftUI focus too
        // when it can, but its keys do not depend on that
        requestFocus(.tabBar)
        installTabBarMonitors()
    }

    func leaveTabBar(focusPane: Bool) {
        guard tabBarActive else { return }
        tabBarActive = false
        removeTabBarMonitors()
        if focusPane { focusActivePane() }
    }

    private func installTabBarMonitors() {
        // monitors are called on the main thread; only plain scalars cross the
        // isolation boundary so the event itself stays out of the closure
        tabBarKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let mods = event.modifierFlags
            let consumed = MainActor.assumeIsolated {
                guard let self, self.tabBarActive else { return false }
                return self.handleTabBarKey(code: code, mods: mods)
            }
            return consumed ? nil : event
        }
        // a click anywhere puts the keyboard back where it was clicked
        tabBarClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.leaveTabBar(focusPane: false) }
            return event
        }
    }

    private func removeTabBarMonitors() {
        if let m = tabBarKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = tabBarClickMonitor { NSEvent.removeMonitor(m) }
        tabBarKeyMonitor = nil
        tabBarClickMonitor = nil
    }

    /// Keys while the strip has the keyboard. Returns true when the event is
    /// consumed. ⌘/⌃/⌥ combinations are left to the menus, except ⌘← which is
    /// the move to the sidebar sitting left of the strip.
    private func handleTabBarKey(code: UInt16, mods rawMods: NSEvent.ModifierFlags) -> Bool {
        let noise: NSEvent.ModifierFlags = [.function, .numericPad, .capsLock, .shift]
        let mods = rawMods
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(noise)
        if mods == .command {
            guard code == 123 else { return false }
            focusSidebar()
            return true
        }
        guard mods.isEmpty else { return false }
        switch code {
        case 123: moveTab(-1)                                  // ←
        case 124: moveTab(1)                                   // →
        case 125, 36, 53, 48: leaveTabBar(focusPane: true)     // ↓, ⏎, Esc, ⇥
        default: break                                         // stay in the strip
        }
        return true
    }

    /// ⌥⌘S — fold/unfold the favourites sidebar. Hiding it while it has
    /// focus hands the keyboard back to the active pane.
    func toggleSidebar() {
        sidebarVisible.toggle()
        if !sidebarVisible, let tab = activeTab {
            requestFocus(.pane(tab.activePane.id))
        }
    }

    /// ⌘0 / ⌘← — focus the sidebar, unfolding it first if hidden.
    func focusSidebar() {
        sidebarVisible = true
        requestFocus(.sidebar)
    }

    // MARK: - Tabs

    func newTab(at url: URL? = nil) {
        let dir = url ?? activePane?.directory ?? FileManager.default.homeDirectoryForCurrentUser
        let tab = TabState(directory: dir, app: self)
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        requestFocus(.pane(tab.activePane.id))
    }

    func closeTab(_ index: Int, force: Bool = false) {
        guard tabs.indices.contains(index) else { return }
        // closing the tab ends the terminal's processes, so anything still
        // running in it gets a say first
        if !force, let program = tabs[index].terminal?.runningProgram {
            closeTabPrompt = CloseTabPrompt(tab: tabs[index].id, program: program)
            return
        }
        tabs[index].shutdown()
        tabs.remove(at: index)
        if tabs.isEmpty {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        activeTabIndex = min(activeTabIndex, tabs.count - 1)
        // ⌘W pressed *in* the tab strip leaves the keyboard there: closing a
        // tab is usually one of several, and being dropped into the next tab's
        // file list after each one means climbing back with ⌘↑ every time.
        if tabBarActive {
            requestFocus(.tabBar)
        } else {
            focusActivePane()
        }
    }

    func closeActiveTab() { closeTab(activeTabIndex) }

    /// Is one of this window's tabs already showing this folder?
    func hasTab(at folder: URL) -> Bool {
        tabs.contains { $0.panes.contains { $0.directory.path == folder.path } }
    }

    /// Show a folder because something outside Marina asked for it. An
    /// existing tab beats a new one — asking twice for the same folder should
    /// not leave two tabs on it.
    func show(folder: URL, selecting file: URL? = nil) {
        if let index = tabs.firstIndex(where: { tab in
            tab.panes.contains { $0.directory.path == folder.path }
        }) {
            DebugLog.open("tab \(index) is already there — switching to it")
            selectTab(index)
            // the pane showing it may be the second one
            if let tab = activeTab,
               let pane = tab.panes.firstIndex(where: { $0.directory.path == folder.path }) {
                tab.activePaneIndex = pane
            }
        } else {
            DebugLog.open("no tab there — new tab (\(tabs.count) before)")
            newTab(at: folder)
        }
        if let file { activePane?.reveal(file) }
        focusActivePane()
    }

    func confirmCloseTab(_ prompt: CloseTabPrompt) {
        closeTabPrompt = nil
        guard let index = tabs.firstIndex(where: { $0.id == prompt.tab }) else { return }
        closeTab(index, force: true)
    }

    /// The window is going away and takes its tabs with it. Nothing asks here —
    /// `NSWindow.willCloseNotification` arrives when the decision is already
    /// made — but leaving the shells running unseen is the bug this fixes.
    func shutdownAllTabs() {
        for tab in tabs { tab.shutdown() }
        tabs.removeAll()
    }

    /// `focusPane: false` keeps the keyboard where it is — used while arrowing
    /// through the tab bar, where the tabs change under a stationary focus.
    func selectTab(_ index: Int, focusPane: Bool = true) {
        guard tabs.indices.contains(index) else { return }
        activeTabIndex = index
        if focusPane { focusActivePane() }
    }

    /// ← / → inside the tab bar: move to the neighbouring tab, no wrap
    /// (spatial movement stops at the ends, like a mouse would).
    func moveTab(_ delta: Int) {
        selectTab(activeTabIndex + delta, focusPane: false)
    }

    func nextTab() {
        guard tabs.count > 1 else { return }
        selectTab((activeTabIndex + 1) % tabs.count)
    }

    func prevTab() {
        guard tabs.count > 1 else { return }
        selectTab((activeTabIndex + tabs.count - 1) % tabs.count)
    }

    func openSelectionInNewTab() {
        guard let pane = activePane else { return }
        let dirs = pane.selectedEntries.filter { $0.isNavigable }
        if dirs.isEmpty { newTab(at: pane.directory); return }
        for d in dirs { newTab(at: d.url) }
    }

    // MARK: - Navigation (active pane)

    func openSelectedItems() {
        guard let pane = activePane else { return }
        let sel = pane.selectedEntries
        if sel.count == 1, sel[0].isNavigable {
            pane.navigate(to: sel[0].url)
            return
        }
        for e in sel where !e.isNavigable {
            NSWorkspace.shared.open(e.url)
        }
    }

    /// Enclosing folder — ← or ⌫ in a pane, and the toolbar's up button.
    func goUp() { activePane?.goUp() }

    func enterTerminal() {
        leaveTabBar(focusPane: false)
        activeTab?.enterTerminal()
    }
    func goBack() { activePane?.goBack() }
    func goForward() { activePane?.goForward() }

    func goHome() {
        activePane?.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }

    func toggleHidden() {
        activePane?.showHidden.toggle()
    }

    // MARK: - Panes

    /// ⌘2 — the same folder in both panes, not the selected one.
    ///
    /// Opening the selection was the old behaviour and it made the second pane
    /// a dead end: the sidebar drives the *active* pane, so after ⌘2 you had
    /// two panes showing different folders and no way to send either of them
    /// somewhere else from the sidebar without first walking back. Same folder
    /// twice means the left one can then be steered from the sidebar, which is
    /// the move that makes a two-pane copy work. The context menu's
    /// "Open Second Pane Here" still opens a named folder.
    func openInSecondPane() {
        guard let tab = activeTab, let pane = activePane else { return }
        tab.openInSecondPane(pane.directory)
    }

    /// ⌘1 — one file pane, whichever of the two companions was open.
    func singlePane() {
        guard let tab = activeTab else { return }
        if tab.viewerVisible { tab.toggleViewer() }
        tab.closeSecondPane()
    }

    /// ⌘3 — the viewer beside the file list.
    func toggleViewer() { activeTab?.toggleViewer() }

    // MARK: - Terminal

    // the terminal takes the keyboard through AppKit, so the tab strip has to
    // let go of it explicitly on the way there
    func toggleTerminal() {
        leaveTabBar(focusPane: false)
        activeTab?.toggleTerminal()
    }

    func toggleTerminalMax() {
        leaveTabBar(focusPane: false)
        activeTab?.toggleTerminalMaximized()
    }

    func cdTerminal() { activeTab?.sendTerminalCD() }

    /// Sidebar action: point the tab's shell at a folder and focus the terminal.
    func openInTerminal(_ url: URL) {
        guard let tab = activeTab else { return }
        leaveTabBar(focusPane: false)
        tab.sendTerminalCD(to: url)
        tab.enterTerminal()
    }

    // MARK: - File operations

    func newFolderInActivePane() {
        guard let pane = activePane else { return }
        let url = unusedURL(in: pane.directory, base: "untitled folder")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        FileUndo.shared.record(.init(title: "New Folder", created: [url]))
        pane.reload()
        pane.select(url)
        renameTarget = RenameRequest(url: url, currentName: url.lastPathComponent)
    }

    /// Right-click ▸ New Markdown File — create an empty .md here, name it,
    /// and hand it to whatever opens .md files (Typora, …).
    func newMarkdownInActivePane() {
        guard let pane = activePane else { return }
        let url = unusedURL(in: pane.directory, base: "untitled", ext: "md")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            errorMessage = "Could not create \(url.lastPathComponent) here"
            return
        }
        FileUndo.shared.record(.init(title: "New File", created: [url]))
        pane.reload()
        pane.select(url)
        renameTarget = RenameRequest(url: url, currentName: url.lastPathComponent, isNew: true)
    }

    /// "untitled.md", then "untitled 2.md", … — never overwrite what is there.
    private func unusedURL(in directory: URL, base: String, ext: String = "") -> URL {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = directory.appendingPathComponent(base + suffix)
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(i)\(suffix)")
            i += 1
        }
        return candidate
    }

    /// Set by ⌘X: the files on the clipboard are there to be moved, not
    /// copied. Held with the pasteboard's change count, so a later copy —
    /// here or in any other app — quietly turns it back into a copy.
    private var cutChangeCount: Int?

    var clipboardIsCut: Bool {
        cutChangeCount != nil && cutChangeCount == NSPasteboard.general.changeCount
    }

    /// True when key input belongs to a text context (terminal, rename field);
    /// pane file-operations must not fire there.
    var editKeysBelongToText: Bool {
        if activeTab?.terminalHasFocus == true { return true }
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSText || responder is NSTextView {
            return true
        }
        return false
    }

    /// The keyboard is in the ⌘3 viewer — its page, PDF or preview, which takes
    /// it when you drag across it to select. See ViewerContent.
    var viewerHasKeyboard: Bool {
        var view = ownFirstResponder as? NSView
        while let current = view {
            if current is ViewerContent { return true }
            view = current.superview
        }
        return false
    }

    /// Where the keyboard is in THIS window — not the key window's, which is
    /// nil whenever Marina is not the active app.
    private var ownFirstResponder: NSResponder? {
        (MarinaWindows.shared.window(for: self) ?? NSApp.keyWindow)?.firstResponder
    }

    /// Sender is deliberately non-nil: SwiftTerm's `copy(_ sender: Any)` and
    /// friends take a non-optional sender.
    func forwardToResponder(_ selector: String) {
        NSApp.sendAction(Selector((selector)), to: nil, from: NSApp)
    }

    /// ⌘C — the terminal's mouse selection when the terminal has the keyboard,
    /// clipboard copy in other text contexts, Finder-style file copy in panes.
    func smartCopy() {
        logCopy("⌘C  terminal=\(activeTab?.terminal != nil)"
                + " visible=\(activeTab?.terminalVisible ?? false)"
                + " focused=\(activeTab?.terminal?.isFocused ?? false)"
                + " selection=\(activeTab?.terminal?.hasSelection ?? false)"
                + " mouseReporting=\(activeTab?.terminal?.mouseReporting ?? false)"
                + " responder=\(ownFirstResponder.map { "\(type(of: $0))" } ?? "none")")
        if let terminal = activeTab?.terminal, activeTab?.terminalHasFocus == true {
            // nothing selected: leave the clipboard alone rather than copying
            // the file pane's selection behind the user's back
            let copied = terminal.copySelection()
            logCopy(copied ? "  → copied terminal text" : "  → terminal had no selection; clipboard left alone")
            return
        }
        // a selection in the viewer is copied by the viewer; with nothing
        // selected there, nothing — as in the terminal
        if editKeysBelongToText || viewerHasKeyboard {
            logCopy("  → forwarded copy: to the responder")
            forwardToResponder("copy:")
        } else {
            logCopy("  → copied the pane's file selection")
            copyFilesToClipboard()
        }
    }

    /// Why ⌘C did what it did:
    ///   defaults write org.fherwig.marina marina.debugCopy -bool true
    /// then watch /tmp/marina-copy.log.
    private static let debugCopy = UserDefaults.standard.bool(forKey: "marina.debugCopy")

    private func logCopy(_ text: String) {
        guard Self.debugCopy else { return }
        let stamp = Date().formatted(date: .omitted, time: .standard)
        guard let data = "\(stamp)  \(text)\n".data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/marina-copy.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// ⌘X — cut. In a file pane that means "mark these for moving": the
    /// selection goes on the clipboard and the next ⌘V moves it rather than
    /// copying. Nothing moves on disk until that paste, so a cut you change
    /// your mind about costs nothing.
    func smartCut() {
        if editKeysBelongToText {
            forwardToResponder("cut:")
            return
        }
        guard let pane = activePane, !pane.selectedEntries.isEmpty else {
            forwardToResponder("cut:")
            return
        }
        copyFilesToClipboard()
        cutChangeCount = NSPasteboard.general.changeCount
    }

    /// ⌘V — clipboard paste in text contexts, paste files into the active pane.
    func smartPaste() {
        if let terminal = activeTab?.terminal, activeTab?.terminalHasFocus == true {
            terminal.pasteClipboard()
            return
        }
        if editKeysBelongToText {
            forwardToResponder("paste:")
            return
        }
        let pasteboard = NSPasteboard.general
        guard let pane = activePane,
              let urls = pasteboard.readObjects(
                  forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]
              ) as? [URL],
              !urls.isEmpty else {
            forwardToResponder("paste:")
            return
        }
        let move = clipboardIsCut
        cutChangeCount = nil
        transfer(urls, into: pane.directory, move: move)
    }

    func copyFilesToClipboard() {
        guard let pane = activePane else { return }
        let urls = pane.selectedEntries.map(\.url)
        guard !urls.isEmpty else { return }
        cutChangeCount = nil
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // an image the viewer is showing goes as file AND picture
        if urls.count == 1, MediaKind(url: urls[0]) == .image,
           activeTab?.viewerVisible == true {
            pasteboard.writeObjects([ImageClipboard.item(for: urls[0])])
            return
        }
        pasteboard.writeObjects(urls as [NSURL])
    }

    /// Files dropped somewhere — on a pane's empty space (its folder) or on a
    /// folder's row. What the drop MEANS is Finder's rule, so a drag does the
    /// same thing here as there: same disk moves, another disk copies, ⌥
    /// forces a copy and ⌘ forces a move. Read from the keys held at the drop.
    func drop(_ urls: [URL], into folder: URL) {
        let keys = NSEvent.modifierFlags
        let move = DropIntent.shouldMove(urls, into: folder,
                                         option: keys.contains(.option),
                                         command: keys.contains(.command))
        transfer(urls, into: folder, move: move)
    }

    /// Copy or move files into a folder, as one undoable change. The single
    /// path every paste, drop and pane-to-pane transfer goes through.
    func transfer(_ urls: [URL], into folder: URL, move: Bool) {
        let fm = FileManager.default
        var moves: [(from: URL, to: URL)] = []
        var created: [URL] = []
        for source in urls {
            // already there: dropping a file back onto its own folder is a no-op
            guard source.deletingLastPathComponent().standardizedFileURL.path
                    != folder.standardizedFileURL.path else { continue }
            // a folder dropped onto itself or into its own subfolder would
            // recurse forever (copy) or vanish into itself (move)
            let src = source.standardizedFileURL.path, dst = folder.standardizedFileURL.path
            // let go over its own row: picked up and put down, as in Finder
            if dst == src { continue }
            if dst.hasPrefix(src + "/") {
                errorMessage = "Can't put “\(source.lastPathComponent)” inside itself"
                continue
            }
            let dest = folder.appendingPathComponent(source.lastPathComponent)
            guard !fm.fileExists(atPath: dest.path) else {
                errorMessage = "“\(source.lastPathComponent)” already exists in \(folder.lastPathComponent)"
                continue
            }
            do {
                if move {
                    try fm.moveItem(at: source, to: dest)
                    moves.append((source, dest))
                } else {
                    try fm.copyItem(at: source, to: dest)
                    created.append(dest)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        let count = moves.count + created.count
        FileUndo.shared.record(.init(title: FileUndo.title(move ? "Move" : "Copy", count: count),
                                     moves: moves, created: created))
        // the source folder empties and the target fills, and either may be
        // on screen in this tab, another tab or another window
        MarinaWindows.shared.reloadAllPanes()
    }

    // MARK: - Undo

    /// ⌘Z — undo the last change to the disk. Not in a text field (the rename
    /// sheet undoes its typing) and not in the terminal, where ⌘Z reaching
    /// back to move files around would be a nasty surprise.
    func smartUndo() {
        if activeTab?.terminalHasFocus == true { return }
        if editKeysBelongToText { forwardToResponder("undo:"); return }
        if let problem = FileUndo.shared.undo() { errorMessage = "Undo was incomplete:\n" + problem }
        MarinaWindows.shared.reloadAllPanes()
    }

    /// ⇧⌘Z — make it again.
    func smartRedo() {
        if activeTab?.terminalHasFocus == true { return }
        if editKeysBelongToText { forwardToResponder("redo:"); return }
        if let problem = FileUndo.shared.redo() { errorMessage = "Redo was incomplete:\n" + problem }
        MarinaWindows.shared.reloadAllPanes()
    }

    func renameSelected() {
        guard !editKeysBelongToText else { return }
        guard let entry = activePane?.selectedEntries.first else { return }
        renameTarget = RenameRequest(url: entry.url, currentName: entry.name)
    }

    func performRename(_ request: RenameRequest, to newName: String) {
        var trimmed = newName.trimmingCharacters(in: .whitespaces)
        // typing "notes" for a new markdown file means notes.md
        if request.isNew, !trimmed.isEmpty, !trimmed.contains(".") {
            trimmed += ".md"
        }
        var final = request.url
        if !trimmed.isEmpty, trimmed != request.currentName {
            let dest = request.url.deletingLastPathComponent().appendingPathComponent(trimmed)
            do {
                try FileManager.default.moveItem(at: request.url, to: dest)
                FileUndo.shared.record(.init(title: "Rename", moves: [(request.url, dest)]))
                final = dest
                activePane?.reload()
                activePane?.select(dest)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if request.isNew { NSWorkspace.shared.open(final) }
    }

    /// Cancelling the sheet for a just-created file means "never mind" — the
    /// placeholder goes away again, as long as nothing has been written to it.
    func cancelRename(_ request: RenameRequest) {
        guard request.isNew else { return }
        let size = (try? request.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size == 0 {
            try? FileManager.default.removeItem(at: request.url)
            FileUndo.shared.forget(created: request.url)
        }
        activePane?.reload()
    }

    func moveToTrash() {
        guard let pane = activePane else { return }
        var moves: [(from: URL, to: URL)] = []
        for e in pane.selectedEntries {
            var parked: NSURL?
            do {
                try FileManager.default.trashItem(at: e.url, resultingItemURL: &parked)
                // where it landed in the Trash is what ⌘Z puts back
                if let parked { moves.append((e.url, parked as URL)) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        FileUndo.shared.record(.init(title: FileUndo.title("Move to Trash", count: moves.count),
                                     moves: moves))
        pane.reload()
    }

    func copyToOtherPane(move: Bool) {
        guard !editKeysBelongToText else { return }
        guard let tab = activeTab, tab.isDual,
              let pane = activePane, let dest = tab.otherPane else { return }
        transfer(pane.selectedEntries.map(\.url), into: dest.directory, move: move)
    }

    /// ⌥⌘O — the applications that can open the selection, as a menu at the
    /// pane. Finder's "Open With", without the trip through a context menu.
    func openWith() {
        guard !editKeysBelongToText, let pane = activePane,
              !pane.selectedEntries.isEmpty else { return }
        openWithGen += 1
        openWithRequest = OpenWithRequest(pane: pane.id, gen: openWithGen)
    }

    /// Every application that claims the selection, the default one first.
    /// Built from the first item: a mixed selection is opened with whatever
    /// suits the one the list was made for, which is how Finder behaves too.
    static func applications(opening urls: [URL]) -> [URL] {
        guard let first = urls.first else { return [] }
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: first)
        // Two copies of an app — an old Numbers left beside the current one —
        // would otherwise put two identical, untellable-apart lines in the
        // menu. LaunchServices returns them in order of preference, so the
        // first of each name is the one to keep.
        var seen = Set<String>()
        if let preferred { seen.insert(appName(preferred)) }
        var rest: [URL] = []
        for url in NSWorkspace.shared.urlsForApplications(toOpen: first)
        where url.path != preferred?.path {
            guard seen.insert(appName(url)).inserted else { continue }
            rest.append(url)
        }
        rest.sort { appName($0).localizedStandardCompare(appName($1)) == .orderedAscending }
        return (preferred.map { [$0] } ?? []) + rest
    }

    static func appName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }

    func open(_ urls: [URL], with application: URL) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: application,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func copyPath() {
        guard let pane = activePane else { return }
        let urls = pane.selectedEntries.map(\.url)
        let paths = (urls.isEmpty ? [pane.directory] : urls).map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }

    /// ⇧⌥⌘C — the folder the pane is SHOWING, whatever is selected in it.
    /// Copy Path (⌥⌘C) is the selected items'; a pane always has a selection,
    /// so it never reached the folder.
    func copyFolderPath() {
        guard let pane = activePane else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pane.directory.path, forType: .string)
    }

    func revealFolderInFinder() {
        guard let pane = activePane else { return }
        NSWorkspace.shared.activateFileViewerSelecting([pane.directory])
    }

    func revealInFinder() {
        guard let pane = activePane else { return }
        let urls = pane.selectedEntries.map(\.url)
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [pane.directory] : urls)
    }

    // MARK: - Favourites

    /// ⌥⌘← — add the selection (files or folders) to the sidebar;
    /// with nothing selected, the current folder.
    func addSelectionToFavourites() {
        guard let pane = activePane, !editKeysBelongToText else { return }
        let urls = pane.selectedEntries.map(\.url)
        for url in (urls.isEmpty ? [pane.directory] : urls) {
            addFavourite(url)
        }
    }

    func addFavourite(_ url: URL) { FavouritesStore.shared.add(url) }

    func removeFavourite(_ url: URL) { FavouritesStore.shared.remove(url) }

    /// Sidebar ▸ New Section… — the sheet does the naming.
    func newFavouriteSection() {
        sectionPrompt = SectionPrompt(target: nil,
                                      name: FavouritesStore.shared.uniqueSectionName(),
                                      returnTo: focusedTarget)
    }

    func renameFavouriteSection(_ id: UUID) {
        guard let section = FavouritesStore.shared.sections.first(where: { $0.id == id }) else { return }
        sectionPrompt = SectionPrompt(target: id, name: section.name, returnTo: focusedTarget)
    }

    // MARK: - Claude sessions

    /// The refresh button in the sidebar, and Go ▸ Refresh Claude Sessions.
    func refreshClaudeSessions() { ClaudeSessionsStore.shared.refresh() }

    func refreshVolumes() { VolumesStore.shared.refresh() }

    func refreshVolumesIfNeeded() { VolumesStore.shared.refreshIfNeeded() }

    /// Full Disk Access is the switch that unlocks the protected locations
    /// (iCloud Drive and the like). Nothing can grant it programmatically, so
    /// all we can do is open the pane. The URL scheme changed with System
    /// Settings in Ventura, so try the current form first and fall back — the
    /// worst case is landing on Privacy & Security without the section
    /// preselected. Unverified here: opening it would have taken the screen
    /// away from whatever Falk was doing.
    static func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Unmount a volume from the sidebar, the way Finder's eject button does.
    func eject(_ volume: Volume) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
        } catch {
            errorMessage = "Could not eject \(volume.name): \(error.localizedDescription)"
        }
    }

    func refreshClaudeSessionsIfNeeded() { ClaudeSessionsStore.shared.refreshIfNeeded() }

    func collapseAllFavouriteSections() { FavouritesStore.shared.setAllCollapsed(true) }

    func expandAllFavouriteSections() { FavouritesStore.shared.setAllCollapsed(false) }

    func commitSectionPrompt(_ prompt: SectionPrompt, name: String) {
        if let target = prompt.target {
            FavouritesStore.shared.renameSection(target, to: name)
        } else {
            FavouritesStore.shared.addSection(named: name)
        }
    }
}
