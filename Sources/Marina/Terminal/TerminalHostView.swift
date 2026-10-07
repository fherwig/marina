import SwiftUI
import AppKit
import SwiftTerm

/// Hosts the session's own, long-lived terminal view. The NSView belongs to the
/// TerminalSession, not to this representable, so moving the terminal in the
/// layout (under the left pane only, or across the whole width) re-parents the
/// same view and leaves the shell running.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession

    // There used to be a hunt here for the nearest NSSplitView, to size a
    // VSplitView divider. The VSplitView went long ago; the nearest split view
    // above the terminal is now the *sidebar's*, so every time a terminal was
    // hosted the sidebar was set to "window height minus 40 rows" wide.
    func makeNSView(context: Context) -> MarinaTerminalView { session.view }

    func updateNSView(_ nsView: MarinaTerminalView, context: Context) {}
}
