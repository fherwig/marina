import SwiftUI

struct SessionView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: TabState
    var focus: FocusState<FocusTarget?>.Binding
    /// ⌥⌘J — with a second pane or the viewer open, the terminal sits under
    /// the left file pane only and the right side keeps the full height. One
    /// setting for every tab and window: it is a preference about how you work,
    /// not about a particular folder.
    @AppStorage("marina.terminalLeftOnly") private var terminalLeftOnly = false

    private var split: Bool { tab.panes.count > 1 || tab.viewerVisible }

    /// Not a VSplitView: its divider is a one-pixel line to aim at, and the
    /// file pane already ends in a bar. The terminal takes a fixed slice, the
    /// panes take the rest, and that bottom bar is the grip — see
    /// FilePaneView.statusBar.
    var body: some View {
        GeometryReader { geo in
            Group {
                if split, terminalLeftOnly, tab.terminalVisible, !tab.terminalMaximized,
                   let session = tab.terminal {
                    leftOnly(session: session, size: geo.size)
                } else {
                    acrossTheWidth(size: geo.size)
                }
            }
            .onAppear { tab.availableHeight = geo.size.height }
            .onChange(of: geo.size.height) { _, height in tab.availableHeight = height }
        }
    }

    /// The default: panes above, terminal across the whole width below.
    private func acrossTheWidth(size: CGSize) -> some View {
        VStack(spacing: 0) {
            if !(tab.terminalVisible && tab.terminalMaximized) {
                panes(width: size.width)
                    .frame(maxHeight: .infinity)
            }
            if tab.terminalVisible, let session = tab.terminal {
                TerminalHostView(session: session)
                    .frame(maxWidth: .infinity)
                    .frame(height: terminalHeight(total: size.height))
            }
        }
    }

    /// The left column is file pane over terminal; the right one — second pane
    /// or viewer — runs the full height. The divider still sizes the columns,
    /// and the terminal grip is the left pane's bottom bar as before.
    private func leftOnly(session: TerminalSession, size: CGSize) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                FilePaneView(tab: tab, pane: tab.panes[0], paneIndex: 0, focus: focus)
                    .frame(maxHeight: .infinity)
                TerminalHostView(session: session)
                    .frame(height: terminalHeight(total: size.height))
            }
            .frame(width: tab.paneWidth(total: size.width))
            PaneDivider(tab: tab, total: size.width)
            rightSide
                .frame(maxWidth: .infinity)
        }
    }

    /// Whatever shares the window with the left pane.
    @ViewBuilder
    private var rightSide: some View {
        if tab.panes.count > 1 {
            FilePaneView(tab: tab, pane: tab.panes[1], paneIndex: 1, focus: focus)
        } else if tab.viewerVisible {
            ViewerPane(tab: tab, pane: tab.panes[0])
        }
    }

    /// Not an HSplitView either: it divides by the views' own sizes, so a
    /// second pane opened into an established one took whatever was left over
    /// rather than half. The split is ours — equal until the divider is
    /// dragged, and equal again on the next ⌘2.
    @ViewBuilder
    private func panes(width: CGFloat) -> some View {
        if split {
            HStack(spacing: 0) {
                FilePaneView(tab: tab, pane: tab.panes[0], paneIndex: 0, focus: focus)
                    .frame(width: tab.paneWidth(total: width))
                PaneDivider(tab: tab, total: width)
                rightSide
                    .frame(maxWidth: .infinity)
            }
        } else {
            FilePaneView(tab: tab, pane: tab.panes[0], paneIndex: 0, focus: focus)
                .frame(maxWidth: .infinity)
        }
    }

    /// Classic 40-row fold-down: the terminal gets its 40 rows when the window
    /// allows and the file area keeps at least its minimum, until a drag on the
    /// grip says otherwise.
    private func terminalHeight(total: CGFloat) -> CGFloat {
        guard let session = tab.terminal else { return 0 }
        if tab.terminalMaximized { return total }
        let room = max(TabState.minTerminalHeight, total - TabState.minFilesHeight)
        let wanted = tab.terminalHeight ?? session.defaultHeight
        return min(max(wanted, TabState.minTerminalHeight), room)
    }
}

/// The grab area between the panes: a hairline to look at, a wider band to
/// catch, like the bar above the terminal.
private struct PaneDivider: View {
    @ObservedObject var tab: TabState
    let total: CGFloat
    @State private var startWidth: CGFloat?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            Divider()
        }
        .frame(width: 6)
        .contentShape(Rectangle())
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        // a stuck resize cursor is worse than no cursor at all
        .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
        .gesture(
            // .global for the same reason the terminal grip uses it: the
            // divider moves as it is dragged, so a translation measured in its
            // own frame chases the pointer
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if startWidth == nil { startWidth = tab.paneWidth(total: total) }
                    let wanted = (startWidth ?? 0) + value.translation.width
                    tab.paneSplit = tab.clampPaneWidth(wanted, total: total) / max(total, 1)
                }
                .onEnded { _ in startWidth = nil }
        )
    }
}
