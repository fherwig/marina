import SwiftUI

/// Compact keyboard cheat sheet, in the Marina Keys panel (HelpPanel): ⌃⌘H
/// or the toolbar's "?".
struct HelpView: View {
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Marina Keys")
                    .uiFont(13, weight: .bold)
                section("Navigate", [
                    ("↑ ↓", "Move selection"),
                    ("← →", "Enclosing folder / descend"),
                    ("⏎  ⌘O", "Open folder / file"),
                    ("⌫", "Enclosing folder"),
                    ("Space  ⌘Y", "Quick Look (↑ ↓ step through files while open)"),
                    ("⌘[  ⌘]", "Back / Forward"),
                    ("⇧⌘H", "Home"),
                    ("⇧⌘.", "Show hidden files"),
                    ("⌘+  ⌘−", "Bigger / smaller text everywhere (⌘= too)"),
                    ("⌃⌘S", "Fold/unfold favourites sidebar"),
                    ("⌃⌘H", "Show / hide this help"),
                ])
                section("Move between units (⌘ + arrow)", [
                    ("⌘← ⌘→", "Sidebar ↔ left pane ↔ right pane"),
                    ("⌘↑", "Files → tab bar (terminal → files)"),
                    ("⌘↓", "Tab bar → files → terminal"),
                ])
                section("Panes & Tabs", [
                    ("⌘2", "Second pane, same folder, equal halves"),
                    ("⌘3", "Viewer — images, video, audio, PDF, text"),
                    ("⌘4", "Tiles or list, remembered per folder"),
                    ("⌥⌘+  ⌥⌘−", "Bigger / smaller tiles"),
                    ("Tiles: Space", "Mark or unmark the cursor's tile; Esc unmarks all"),
                    ("Drag, ⌘C", "In the viewer: copy the selected text"),
                    ("⌘1", "Single pane"),
                    ("⇥", "Switch pane"),
                    ("⌘M", "Move selection to other pane"),
                    ("⌥⌘N", "New Marina window (own tabs & shells)"),
                    ("⌘T  ⌘W", "New / close tab"),
                    ("⌘↑ then ← →", "Move between tabs; ⏎ or ↓ back to files"),
                    ("⌃⌘←  ⌃⌘→", "Previous / next tab"),
                    ("⌘⏎", "Open selection in new tab"),
                    ("⌘,", "Settings: text size, start folder, hidden files, terminal font and colours, following, sidebar sections, voice input"),
                ])
                section("Sidebar", [
                    ("⌘←  ⌘0", "Focus sidebar"),
                    ("← →", "Fold / unfold the section"),
                    ("a…z", "Jump to a favourite; repeat to cycle"),
                    ("Space", "Action menu (remove, move to section, rename…)"),
                    ("⇧⌥⌘N", "New section"),
                    ("⇧⌥⌘R", "Rescan the Claude Sessions section"),
                    ("⌥⌘←", "Add selection to sidebar (files or folders)"),
                    ("Drag", "Drop items to add them; drag a favourite to reorder"),
                ])
                section("Terminal", [
                    ("⌘`", "Terminal: show + focus / hide (key left of 1: ⌘^ on a German keyboard)"),
                    ("⌘↓  ⌘↑", "Down into terminal / up to files"),
                    ("⌥⌘`", "Terminal full height"),
                    ("Drag the bar", "Above the terminal: make it taller or shorter"),
                    ("⌘J", "cd terminal to this folder"),
                    ("⌥⌘J", "Terminal under left pane only (with ⌘2 / ⌘3)"),
                    ("Hold Space", "Dictate with Whisper, once chosen in Settings ▸ Voice; Esc cancels"),
                    ("—", "Shell follows the panes when idle at its prompt"),
                    ("Drag", "Select text (double / triple: word, line)"),
                    ("⇧-drag", "Select when a plain drag selects nothing (or turn Terminal ▸ Mouse Reporting off)"),
                    ("⌘C  ⌘V", "Copy selection / paste"),
                ])
                section("Files", [
                    ("⌘Z  ⇧⌘Z", "Undo / redo the last move, copy, rename, trash"),
                    ("Drag", "Same disk moves, other disk copies (⌥ copy, ⌘ move)"),
                    ("⌘C  ⌘V", "Copy / paste files (Finder-compatible)"),
                    ("⌘X  ⌘V", "Cut, then paste to move it there"),
                    ("⌘R", "Rename"),
                    ("⌘⌫", "Move to Trash"),
                    ("⌘N", "New markdown file here (opens it)"),
                    ("⇧⌘N", "New folder"),
                    ("⌥⌘O", "Open With — other applications"),
                    ("⌥⌘C", "Copy path of the selection"),
                    ("⇧⌥⌘C", "Copy path of the folder (or click the path bar)"),
                ])
                Text("Every action is also in the menus and the right-click menu.")
                    .uiFont(10)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .frame(minWidth: 300 * zoom, maxWidth: .infinity, minHeight: 200 * zoom, maxHeight: .infinity)
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .uiFont(11, weight: .semibold)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0)
                            .uiFont(12, weight: .medium, design: .monospaced)
                            .gridColumnAlignment(.trailing)
                        Text(row.1)
                            .uiFont(12)
                    }
                }
            }
        }
    }
}
