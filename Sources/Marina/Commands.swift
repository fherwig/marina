import SwiftUI
import AppKit

/// Menu bar for whichever Marina window has the keyboard. Each window owns its
/// own AppState, so the commands reach it through the focused scene value
/// rather than holding one instance.
struct MarinaCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    // @AppStorage rather than a hand-made Binding onto UserDefaults: the menu
    // has to notice when the terminal's right-click menu flips it, or the
    // checkmark goes stale
    @AppStorage("marina.terminalLeftOnly") private var terminalLeftOnly = false

    private var app: AppState? { MarinaWindows.shared.current }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Marina") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("New Tab") { app?.newTab() }
                .keyboardShortcut("t")
            Button("Close Tab") { app?.closeActiveTab() }
                .keyboardShortcut("w")
            Divider()
            Button("New Markdown File") { app?.newMarkdownInActivePane() }
                .keyboardShortcut("n")
            Button("New Folder") { app?.newFolderInActivePane() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        // Single owner for the edit keys: Copy is context-aware (clipboard in
        // terminal/text fields, copy-to-other-pane in file panes); the rest
        // forward to the focused view so terminal ⌘V etc. keep working.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { app?.smartCut() }
                .keyboardShortcut("x")
            Button("Copy") { app?.smartCopy() }
                .keyboardShortcut("c")
            Button("Paste") { app?.smartPaste() }
                .keyboardShortcut("v")
            Divider()
            Button("Select All") { app?.forwardToResponder("selectAll:") }
                .keyboardShortcut("a")
        }

        // ⌘M belongs to Move to Other Pane; minimize moves to ⌥⌘M.
        CommandGroup(replacing: .windowSize) {
            Button("Minimize") { NSApp.keyWindow?.miniaturize(nil) }
                .keyboardShortcut("m", modifiers: [.command, .option])
        }

        CommandMenu("Go") {
            Button("Open") { app?.openSelectedItems() }
                .keyboardShortcut("o")
            Button("Enclosing Folder (← / ⌫)") { app?.goUp() }
            Divider()
            // ⌘-arrows move between logical units in the direction they sit
            // on screen; the file tree is plain ← / →.
            Button("Focus Up — Files, then Tabs") { app?.focusUp() }
                .keyboardShortcut(.upArrow)
            Button("Focus Down — Terminal") { app?.focusDown() }
                .keyboardShortcut(.downArrow)
            Divider()
            Button("Back") { app?.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { app?.goForward() }
                .keyboardShortcut("]")
            Divider()
            Button("Home") { app?.goHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Focus Sidebar") { app?.focusSidebar() }
                .keyboardShortcut("0")
            Button("Refresh Claude Sessions") { app?.refreshClaudeSessions() }
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
            // no shortcut: mounting and unmounting refresh the section by
            // themselves, so this is only for a cloud drive that came or went
            Button("Refresh Volumes") { app?.refreshVolumes() }
            Button("Switch Pane (⇥)") { app?.activeTab?.switchPane() }
            Divider()
            Button("Toggle Hidden Files") { app?.toggleHidden() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }

        CommandMenu("Actions") {
            Button("Open in Second Pane") { app?.openInSecondPane() }
                .keyboardShortcut("2")
            Button("Viewer — Images, Media, Text") { app?.toggleViewer() }
                .keyboardShortcut("3")
            Button("Single Pane") { app?.singlePane() }
                .keyboardShortcut("1")
            Button("Open in New Tab") { app?.openSelectionInNewTab() }
                .keyboardShortcut(.return)
            Divider()
            Button("Rename") { app?.renameSelected() }
                .keyboardShortcut("r")
            Button("Copy to Other Pane") { app?.copyToOtherPane(move: false) }  // ⌘C via Edit ▸ Copy
            Button("Move to Other Pane") { app?.copyToOtherPane(move: true) }
                .keyboardShortcut("m")
            Button("Move to Trash") { app?.moveToTrash() }
                .keyboardShortcut(.delete)
            Divider()
            Button("Add to Favourites") { app?.addSelectionToFavourites() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            // ⌃⌘N belongs to Notification Centre.
            Button("New Sidebar Section…") { app?.newFavouriteSection() }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])
            Button("Collapse All Sections") { app?.collapseAllFavouriteSections() }
            Button("Expand All Sections") { app?.expandAllFavouriteSections() }
            Divider()
            Button("Open With…") { app?.openWith() }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Button("Copy Path") { app?.copyPath() }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Reveal in Finder") { app?.revealInFinder() }
        }

        CommandMenu("Terminal") {
            // the key left of "1", whatever it prints on this keyboard —
            // ` on a US board, ^ on a German one. See KeyboardLayout.
            Button("Toggle Terminal") { app?.toggleTerminal() }
                .keyboardShortcut(KeyEquivalent(KeyboardLayout.terminalKeyCharacter))
            Button("Focus Terminal (⌘↓)") { app?.enterTerminal() }
            Button("Terminal Full Height") { app?.toggleTerminalMax() }
                .keyboardShortcut(KeyEquivalent(KeyboardLayout.terminalKeyCharacter),
                                  modifiers: [.command, .option])
            Button("cd to Active Folder") { app?.cdTerminal() }
                .keyboardShortcut("j")
            // only changes anything with a second pane or the viewer open
            Toggle("Terminal Under Left Pane Only", isOn: $terminalLeftOnly)
                .keyboardShortcut("j", modifiers: [.command, .option])
            Divider()
            Toggle("Panes Follow Terminal", isOn: Binding(
                get: { app?.activeTab?.followTerminal ?? true },
                set: { app?.activeTab?.followTerminal = $0 }
            ))
            Toggle("Terminal Follows Panes", isOn: Binding(
                get: { app?.activeTab?.followPanes ?? true },
                set: { app?.activeTab?.followPanes = $0 }
            ))
            // A claude session turns mouse reporting on, and then a plain drag
            // belongs to claude rather than to text selection. Shift-drag
            // selects regardless; turn this off to get the plain drag back.
            Toggle("Mouse Reporting", isOn: Binding(
                get: { app?.activeTab?.terminal?.mouseReporting ?? true },
                set: { app?.activeTab?.terminal?.mouseReporting = $0 }
            ))
        }

        CommandGroup(replacing: .help) {
            Button("Marina Keys") { app?.helpVisible.toggle() }
                .keyboardShortcut("h", modifiers: [.command, .control])
        }

        CommandGroup(after: .sidebar) {
            Button("Show/Hide Sidebar") { app?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
            Button("Next Tab") { app?.nextTab() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
            Button("Previous Tab") { app?.prevTab() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
        }
    }
}
