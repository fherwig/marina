import SwiftUI
import AppKit

/// The bar between the file panes and the terminal: drag it to size the
/// terminal, up for more. One bar across everything that sits on the terminal,
/// the viewer and the foot of the pane divider included. It used to be each
/// file pane's own 8pt bottom strip, which left the viewer's half of the width
/// dead and put the pane divider's sideways cursor in the middle of it.
struct TerminalGrip: View {
    @ObservedObject var tab: TabState
    static let height: CGFloat = 12

    var body: some View {
        GripBar(tab: tab)
            .frame(height: Self.height)
            // the hairline lies on the bar rather than above it, so aiming at
            // the line catches the bar too
            .overlay(alignment: .top) { Divider().allowsHitTesting(false) }
    }
}

private struct GripBar: NSViewRepresentable {
    let tab: TabState
    func makeNSView(context: Context) -> GripView { GripView() }
    func updateNSView(_ view: GripView, context: Context) { view.tab = tab }
}

/// AppKit rather than a SwiftUI drag gesture, for what the gesture got wrong:
/// the resize cursor comes from the view's own tracking area, so it shows
/// wherever the bar takes the mouse (onHover's push and pop lost out to the
/// table and the terminal either side); the first click in an inactive window
/// already grabs; and the cursor holds while the pointer runs ahead of a bar
/// that has stopped at its limit.
final class GripView: NSView {
    weak var tab: TabState?
    private var start: (y: CGFloat, height: CGFloat)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // .inVisibleRect keeps the area on the bar as the bar moves and resizes
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Terminal size")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeUpDown.set() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let tab else { return }
        start = (event.locationInWindow.y, tab.shownTerminalHeight)
        NSCursor.resizeUpDown.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let tab, let start else { return }
        // window coordinates, which the bar moving under the pointer does not
        // shift; they grow upwards, and so does the terminal. Clamped as it
        // goes, so travel past a limit is not banked and owed back.
        tab.terminalHeight = tab.clampTerminalHeight(start.height + event.locationInWindow.y - start.y)
        NSCursor.resizeUpDown.set()
    }

    override func mouseUp(with event: NSEvent) { start = nil }
}
