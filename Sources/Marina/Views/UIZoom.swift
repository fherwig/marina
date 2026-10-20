import SwiftUI

/// ⌘+ / ⌘− — one size for everything Marina draws itself: file lists, sidebar,
/// tabs, path bars, the terminal, the viewer's text, the help. One setting for
/// every window, remembered, like ⌥⌘J: it is about your eyes and your screen,
/// not about a folder. Menus, alerts, buttons and the toolbar are the system's
/// and keep its size; so do PDFs, pictures and Word pages in the viewer, which
/// fit themselves to the pane.
enum UIZoom {
    static let key = "marina.zoom"
    /// Browser-like steps, so every press is a change you can see.
    static let steps: [Double] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.4, 1.6, 1.8, 2.0]
    /// Posted after every change, for what SwiftUI does not redraw: the
    /// terminals.
    static let changed = Notification.Name("MarinaZoomChanged")

    static var factor: CGFloat {
        let stored = UserDefaults.standard.double(forKey: key)
        return stored > 0 ? min(max(stored, steps[0]), steps[steps.count - 1]) : 1
    }

    static var canZoomIn: Bool { factor < steps[steps.count - 1] - 0.001 }
    static var canZoomOut: Bool { factor > steps[0] + 0.001 }

    static func zoomIn() {
        let now = factor
        if let next = steps.first(where: { $0 > now + 0.001 }) { set(next) }
    }

    static func zoomOut() {
        let now = factor
        if let next = steps.last(where: { $0 < now - 0.001 }) { set(next) }
    }

    static func actualSize() { set(1) }

    /// The step a stored size is closest to — what Settings shows for a size
    /// set some other way.
    static func nearestStep(to value: Double) -> Double {
        steps.min { abs($0 - value) < abs($1 - value) } ?? 1
    }

    /// Any of `steps`: ⌘+ / ⌘−, Actual Size and Settings ▸ Text size.
    static func set(_ value: Double) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

// a hand-written key rather than @Entry: that macro's plugin ships with Xcode,
// and Marina builds without it
private struct UIZoomKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// The ⌘+ / ⌘− factor, set once at each window's root (ContentView).
    var uiZoom: CGFloat {
        get { self[UIZoomKey.self] }
        set { self[UIZoomKey.self] = newValue }
    }
}

extension View {
    /// The system font at `size` points times the zoom: what every
    /// `.font(.system(size:))` in Marina's own views goes through.
    func uiFont(_ size: CGFloat, weight: Font.Weight = .regular,
                design: Font.Design = .default) -> some View {
        modifier(ZoomedFont(size: size, weight: weight, design: design))
    }
}

private struct ZoomedFont: ViewModifier {
    @Environment(\.uiZoom) private var zoom
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * zoom, weight: weight, design: design))
    }
}
