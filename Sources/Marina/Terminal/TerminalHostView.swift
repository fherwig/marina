import SwiftUI
import AppKit
import SwiftTerm

struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> MarinaTerminalView {
        let view = session.view
        // VSplitView never honors idealHeight against a greedy Table, so set
        // the underlying NSSplitView divider to give the terminal its classic
        // 40 rows once the view lands in the hierarchy
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            var candidate: NSView? = view.superview
            while let current = candidate, !(current is NSSplitView) {
                candidate = current.superview
            }
            guard let split = candidate as? NSSplitView,
                  split.arrangedSubviews.count > 1 else { return }
            // full 40 rows when the window affords it; on shorter windows the
            // file area keeps at least ~a third of the split
            let filesFloor = max(160, split.bounds.height * 0.35)
            let target = max(filesFloor, split.bounds.height - session.defaultHeight)
            split.setPosition(target, ofDividerAt: 0)
        }
        return view
    }

    func updateNSView(_ nsView: MarinaTerminalView, context: Context) {}
}
