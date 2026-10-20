import SwiftUI

struct SessionView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: TabState
    var focus: FocusState<FocusTarget?>.Binding
    /// ⌥⌘J — with a second pane or the viewer open, the terminal sits under
    /// the left file pane only and the right side keeps the full height. One
    /// setting for every tab and window: it is a preference about how you
    /// work, not about a particular folder. With Terminal per Pane on, two
    /// file panes have a terminal each, and this is about the viewer alone.
    @AppStorage("marina.terminalLeftOnly") private var terminalLeftOnly = false
    /// Settings ▸ Terminal per Pane; observed so the layout follows a change
    /// at once. TabState reads the same value through Preferences.
    @AppStorage(Preferences.terminalPerPaneKey) private var terminalPerPane = false

    private var split: Bool { tab.panes.count > 1 || tab.viewerVisible }

    /// Not a VSplitView: its divider is a one-pixel line to aim at. The
    /// terminal takes a fixed slice, the panes take the rest, and a bar between
    /// them is the grip — see TerminalGrip.
    var body: some View {
        GeometryReader { geo in
            Group {
                if let maximized = maximizedSecond {
                    // the right pane's terminal takes the whole tab
                    TerminalHostView(session: maximized)
                } else if tab.terminalPerPane || (split && terminalLeftOnly), !mainMaximized {
                    // whether or not a terminal is showing yet: switching to
                    // a different layout as one opens rebuilt both panes, and
                    // a rebuilt pane takes the keyboard back from the terminal
                    // that just opened
                    columns(size: geo.size)
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
                panes(width: size.width, terminalBelow: tab.terminalVisible && tab.terminal != nil)
                    .frame(maxHeight: .infinity)
            }
            if tab.terminalVisible, let session = tab.terminal {
                if !tab.terminalMaximized { TerminalGrip(tab: tab) }
                TerminalHostView(session: session)
                    .frame(maxWidth: .infinity)
                    .frame(height: terminalHeight(total: size.height))
            }
        }
    }

    private func showing(_ slot: TabState.Slot) -> Bool {
        tab.isVisible(slot) && tab.session(slot) != nil
    }

    private var mainMaximized: Bool { tab.terminalVisible && tab.terminalMaximized }

    private var maximizedSecond: TerminalSession? {
        guard tab.terminalPerPane, tab.secondTerminalVisible, tab.secondTerminalMaximized else { return nil }
        return tab.secondTerminal
    }

    /// Two columns, each running the full height: the left pane over its
    /// terminal, and on the right the viewer, or the second pane — over its
    /// own terminal with Terminal per Pane on. The divider still sizes the
    /// columns, each terminal has its grip above it, and the two terminals
    /// share one height so their prompts line up.
    private func columns(size: CGSize) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                FilePaneView(tab: tab, pane: tab.panes[0], paneIndex: 0, focus: focus,
                             terminalBelow: showing(.main))
                    .frame(maxHeight: .infinity)
                if showing(.main), let session = tab.terminal {
                    TerminalGrip(tab: tab)
                    TerminalHostView(session: session)
                        .frame(height: terminalHeight(total: size.height))
                }
            }
            .frame(width: tab.paneWidth(total: size.width))
            PaneDivider(tab: tab, total: size.width)
            VStack(spacing: 0) {
                let second = tab.terminalPerPane && showing(.second) ? tab.secondTerminal : nil
                rightSide(terminalBelow: second != nil)
                    .frame(maxHeight: .infinity)
                if let second {
                    TerminalGrip(tab: tab)
                    TerminalHostView(session: second)
                        .frame(height: terminalHeight(total: size.height))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Whatever shares the window with the left pane.
    @ViewBuilder
    private func rightSide(terminalBelow: Bool) -> some View {
        if tab.panes.count > 1 {
            FilePaneView(tab: tab, pane: tab.panes[1], paneIndex: 1, focus: focus,
                         terminalBelow: terminalBelow)
        } else if tab.viewerVisible {
            ViewerPane(tab: tab, pane: tab.panes[0])
        }
    }

    /// Not an HSplitView either: it divides by the views' own sizes, so a
    /// second pane opened into an established one took whatever was left over
    /// rather than half. The split is ours — equal until the divider is
    /// dragged, and equal again on the next ⌘2.
    @ViewBuilder
    private func panes(width: CGFloat, terminalBelow: Bool) -> some View {
        if split {
            HStack(spacing: 0) {
                FilePaneView(tab: tab, pane: tab.panes[0], paneIndex: 0, focus: focus,
                             terminalBelow: terminalBelow)
                    .frame(width: tab.paneWidth(total: width))
                PaneDivider(tab: tab, total: width)
                rightSide(terminalBelow: terminalBelow)
                    .frame(maxWidth: .infinity)
            }
        } else {
            FilePaneView(tab: tab, pane: tab.panes[0], paneIndex: 0, focus: focus,
                         terminalBelow: terminalBelow)
                .frame(maxWidth: .infinity)
        }
    }

    /// Classic 40-row fold-down: the terminal gets its 40 rows when the window
    /// allows and the file area keeps at least its minimum, until a drag on the
    /// grip says otherwise.
    private func terminalHeight(total: CGFloat) -> CGFloat {
        guard let session = tab.terminal ?? tab.secondTerminal else { return 0 }
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
