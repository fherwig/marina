import SwiftUI

struct SessionView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: TabState
    var focus: FocusState<FocusTarget?>.Binding

    /// Not a VSplitView: its divider is a one-pixel line to aim at, and the
    /// file pane already ends in a bar. The terminal takes a fixed slice, the
    /// panes take the rest, and that bottom bar is the grip — see
    /// FilePaneView.statusBar.
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                if !(tab.terminalVisible && tab.terminalMaximized) {
                    HSplitView {
                        FilePaneView(tab: tab, pane: tab.panes[0], paneIndex: 0, focus: focus)
                            .frame(minWidth: 260)
                        if tab.panes.count > 1 {
                            FilePaneView(tab: tab, pane: tab.panes[1], paneIndex: 1, focus: focus)
                                .frame(minWidth: 260)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                if tab.terminalVisible, let session = tab.terminal {
                    TerminalHostView(session: session)
                        .frame(maxWidth: .infinity)
                        .frame(height: terminalHeight(total: geo.size.height))
                }
            }
            .onAppear { tab.availableHeight = geo.size.height }
            .onChange(of: geo.size.height) { _, height in tab.availableHeight = height }
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
