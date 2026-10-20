import SwiftUI

/// The tab strip is its own keyboard unit: ⌘↑ from a file pane lands here,
/// ← / → move between tabs (the pane below follows immediately, like the
/// sidebar), and ↓ / Return / Esc hand the keyboard back to the file pane.
/// Those keys are handled in AppState while `tabBarActive` is set — see the
/// note there on why this does not go through @FocusState.
struct TabBarView: View {
    @EnvironmentObject var app: AppState
    var focus: FocusState<FocusTarget?>.Binding
    @Environment(\.uiZoom) private var zoom

    private var isFocused: Bool { app.tabBarActive }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(app.tabs.enumerated()), id: \.element.id) { index, tab in
                TabButton(
                    tab: tab,
                    index: index,
                    isActive: index == app.activeTabIndex,
                    barFocused: isFocused
                )
            }
            Button {
                app.newTab()
            } label: {
                Image(systemName: "plus")
                    .uiFont(11, weight: .medium)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .help("New Tab (⌘T)")
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 30 * zoom)
        .background(.bar)
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused(focus, equals: .tabBar)
    }
}

private struct TabButton: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: TabState
    let index: Int
    let isActive: Bool
    let barFocused: Bool

    var body: some View {
        TabChip(
            title: tab.title,
            hasTerminal: tab.hasTerminal,
            isActive: isActive,
            barFocused: barFocused,
            showClose: isActive && app.tabs.count > 1,
            onClose: { app.closeTab(index) }
        )
        .contentShape(Rectangle())
        .help(tab.activePane.directory.path)
        .onTapGesture { app.selectTab(index) }
        .contextMenu {
            Button("Close Tab") { app.closeTab(index) }
        }
    }
}
