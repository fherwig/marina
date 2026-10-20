import AppKit
import SwiftUI

/// Marina Keys in a panel of its own (⌃⌘H, the toolbar's "?"), so it can stay
/// open beside a Marina window while you work in it. It used to be a popover,
/// gone at the first key press.
///
/// It floats above Marina's windows and never takes the keyboard: clicking or
/// scrolling it leaves the keys where they were, so the cheat sheet can be
/// read and followed at once. It steps aside while another app is in front,
/// as Marina's own panels should, and opens where it was last put; the first
/// time, beside the window you are in.
@MainActor
final class HelpPanel {
    static let shared = HelpPanel()

    private lazy var panel: NSPanel = {
        let zoom = UIZoom.factor
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400 * zoom, height: 560 * zoom),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.title = "Marina Keys"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: HelpPanelContent())
        // Marina quits with its last window; an open panel must not keep it
        // running on its own
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let closing = note.object as? NSWindow, closing !== panel else { return }
                let others = NSApp.windows.filter {
                    $0 !== closing && $0 !== panel && $0.isVisible && !($0 is NSPanel)
                }
                if others.isEmpty { panel.close() }
            }
        }
        return panel
    }()

    private static let frameName = "MarinaKeys"

    var isVisible: Bool { panel.isVisible }

    func toggle(beside window: NSWindow?) {
        if panel.isVisible {
            panel.close()
        } else {
            show(beside: window)
        }
    }

    private func show(beside window: NSWindow?) {
        if !panel.setFrameUsingName(Self.frameName) {
            place(beside: window)
        }
        panel.setFrameAutosaveName(Self.frameName)
        // in front, without the keyboard
        panel.orderFront(nil)
    }

    /// To the right of the window if the screen has room there, else to
    /// its left, else over its right edge.
    private func place(beside window: NSWindow?) {
        guard let window, let screen = window.screen ?? NSScreen.main else {
            panel.center()
            return
        }
        let area = screen.visibleFrame
        let size = panel.frame.size
        let gap: CGFloat = 8
        var x = window.frame.maxX + gap
        if x + size.width > area.maxX {
            x = window.frame.minX - gap - size.width
            if x < area.minX { x = max(area.minX, window.frame.maxX - size.width) }
        }
        let y = min(max(window.frame.maxY - size.height, area.minY), area.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// The panel's content: Marina Keys at Marina's text size, which it follows
/// as ⌘+ and ⌘− change it.
private struct HelpPanelContent: View {
    @AppStorage(UIZoom.key) private var zoom = 1.0

    var body: some View {
        HelpView()
            .environment(\.uiZoom, CGFloat(zoom))
    }
}
