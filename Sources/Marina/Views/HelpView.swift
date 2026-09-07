import SwiftUI

/// Compact keyboard cheat sheet, shown from the toolbar "?" button.
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Marina Keys")
                    .font(.headline)
                section("Navigate", [
                    ("↑ ↓", "Move selection"),
                    ("← →", "Enclosing folder / descend"),
                    ("⏎  ⌘O", "Open folder / file"),
                    ("⌫", "Enclosing folder"),
                    ("Space", "Quick Look"),
                    ("⌘[  ⌘]", "Back / Forward"),
                    ("⇧⌘H", "Home"),
                    ("⇧⌘.", "Show hidden files"),
                    ("⌃⌘S", "Fold/unfold favourites sidebar"),
                    ("⌃⌘H", "Show / hide this help"),
                ])
                section("Move between units (⌘ + arrow)", [
                    ("⌘← ⌘→", "Sidebar ↔ left pane ↔ right pane"),
                    ("⌘↑", "Files → tab bar (terminal → files)"),
                    ("⌘↓", "Tab bar → files → terminal"),
                ])
                section("Panes & Tabs", [
                    ("⌘2", "Open selection in second pane"),
                    ("⌘1", "Single pane"),
                    ("⇥", "Switch pane"),
                    ("⌘M", "Move selection to other pane"),
                    ("⌥⌘N", "New Marina window (own tabs & shells)"),
                    ("⌘T  ⌘W", "New / close tab"),
                    ("⌘↑ then ← →", "Move between tabs; ⏎ or ↓ back to files"),
                    ("⌃⌘←  ⌃⌘→", "Previous / next tab"),
                    ("⌘⏎", "Open selection in new tab"),
                ])
                section("Sidebar", [
                    ("⌘←  ⌘0", "Focus sidebar"),
                    ("← →", "Fold / unfold the section"),
                    ("Space", "Action menu (remove, move to section, rename…)"),
                    ("⇧⌥⌘N", "New section"),
                    ("⇧⌥⌘R", "Rescan the Claude Sessions section"),
                    ("⌥⌘←", "Add selection to sidebar (files or folders)"),
                    ("Drag", "Drop items to add them; drag a favourite to reorder"),
                ])
                section("Terminal", [
                    ("⌘`", "Terminal: show + focus / hide"),
                    ("⌘↓  ⌘↑", "Down into terminal / up to files"),
                    ("⌥⌘`", "Terminal full height"),
                    ("⌘J", "cd terminal to this folder"),
                    ("—", "Shell follows the panes when idle at its prompt"),
                    ("Drag", "Select text (double / triple: word, line)"),
                    ("⌘C  ⌘V", "Copy selection / paste"),
                ])
                section("Files", [
                    ("⌘C  ⌘V", "Copy / paste files (Finder-compatible)"),
                    ("⌘X  ⌘V", "Cut, then paste to move it there"),
                    ("⌘R", "Rename"),
                    ("⌘⌫", "Move to Trash"),
                    ("⌘N", "New markdown file here (opens it)"),
                    ("⇧⌘N", "New folder"),
                    ("⌥⌘O", "Open With — other applications"),
                    ("⌥⌘C", "Copy path"),
                ])
                Text("Every action is also in the menus and the right-click menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .frame(width: 380, height: 500)
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .gridColumnAlignment(.trailing)
                        Text(row.1)
                            .font(.system(size: 12))
                    }
                }
            }
        }
    }
}
