import AppKit
import QuickLookUI

/// Space-bar Quick Look, run the way Finder runs it.
///
/// SwiftUI's `.quickLookPreview($url)` hands the panel one file and nothing
/// else. The panel takes the keyboard when it opens, so ↑ and ↓ landed in a
/// panel with one item and nowhere to go. Finder instead CONTROLS the panel:
/// keys the panel does not use itself are passed to its delegate, Finder moves
/// its list selection on ↑ / ↓, and the preview follows. This does the same —
/// the arrows move the file list's selection (scrolling it into view, and
/// taking the ⌘3 viewer along), and the panel shows whatever is selected.
///
/// The panel finds its controller by walking the KEY WINDOW's responder chain
/// for an object that accepts control — measured: with no key window it asks
/// nobody, not even the app delegate, although NSApp.target(forAction:) would
/// have resolved there. So each Marina window gets a QuickLookResponder
/// inserted into its own chain (MarinaWindows.register); the app delegate
/// answers too, as a second chance; and `toggle` takes the panel directly if
/// neither was asked.
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()

    private weak var pane: PaneState?
    /// Moves the pane's selection by one row and scrolls it into view —
    /// supplied by the pane, which owns the table.
    private var step: ((Int) -> Void)?
    private var items: [URL] = []

    private var panel: QLPreviewPanel? {
        QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil
    }

    var isShowing: Bool { panel?.isVisible ?? false }

    /// Space: open on the selection, or close if it is already open for this pane.
    func toggle(for pane: PaneState, step: @escaping (Int) -> Void) {
        if isShowing, self.pane === pane {
            panel?.orderOut(nil)
            return
        }
        self.pane = pane
        self.step = step
        items = pane.selectedEntries.map(\.url)
        guard !items.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.makeKeyAndOrderFront(nil)
        // Normally the panel has asked the app delegate for control by now,
        // and been handed to us. If the responder chain did not get there,
        // take it directly rather than show an empty panel.
        if panel.dataSource !== self {
            panel.dataSource = self
            panel.delegate = self
        }
        panel.reloadData()
    }

    /// The selection moved — by the arrows below, a click, type-ahead: show
    /// what it is on now.
    func selectionChanged(in pane: PaneState) {
        guard isShowing, self.pane === pane else { return }
        items = pane.selectedEntries.map(\.url)
        panel?.reloadData()
    }

    // MARK: - Data source

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { () -> NSURL? in
            items.indices.contains(index) ? items[index] as NSURL : nil
        }
    }

    // MARK: - Delegate

    /// Keys the panel does not handle itself arrive here. ↑ and ↓ move the
    /// file list, as in Finder; Space closes, as it opened. Everything else
    /// (Esc, the panel's own controls) is the panel's.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        let code = event.keyCode
        return MainActor.assumeIsolated {
            switch code {
            case 125: step?(1); return true      // ↓
            case 126: step?(-1); return true     // ↑
            case 49: panel?.orderOut(nil); return true   // Space
            default: return false
            }
        }
    }
}

/// Sits in a Marina window's responder chain, right after the window, so the
/// Quick Look panel finds a controller wherever the keyboard is in that window
/// — file table, sidebar, terminal — and is handed to QuickLook.shared.
final class QuickLookResponder: NSResponder {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLook.shared
            panel.delegate = QuickLook.shared
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    /// Insert once per window, between the window and whatever followed it.
    static func install(in window: NSWindow) {
        if window.nextResponder is QuickLookResponder { return }
        let responder = QuickLookResponder()
        responder.nextResponder = window.nextResponder
        window.nextResponder = responder
    }
}
