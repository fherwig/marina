import SwiftUI

/// The tab strip is its own keyboard unit: ⌘↑ from a file pane lands here,
/// ← / → move between tabs (the pane below follows immediately, like the
/// sidebar), and ↓ / Return / Esc hand the keyboard back to the file pane.
/// Those keys are handled in AppState while `tabBarActive` is set — see the
/// note there on why this does not go through @FocusState.
struct TabBarView: View {
    @EnvironmentObject var app: AppState
    var focus: FocusState<FocusTarget?>.Binding

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
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .help("New Tab (⌘T)")
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
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

    private var highlighted: Bool { isActive && barFocused }

    var body: some View {
        HStack(spacing: 5) {
            Text(tab.title)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .lineLimit(1)
            if tab.terminal != nil {
                Image(systemName: "terminal")
                    .font(.system(size: 9))
                    .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
            if isActive && app.tabs.count > 1 {
                Button {
                    app.closeTab(index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help("Close Tab (⌘W)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            highlighted
                ? AnyShapeStyle(Color.accentColor)
                : (isActive ? AnyShapeStyle(.selection.opacity(0.18)) : AnyShapeStyle(.clear)),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .contentShape(Rectangle())
        .onTapGesture { app.selectTab(index) }
        .contextMenu {
            Button("Close Tab") { app.closeTab(index) }
        }
    }
}
