import SwiftUI

/// How one tab looks — kept apart from TabButton, which knows about the app,
/// so the look can be drawn on its own.
///
/// The active tab has to be unmistakable at a glance. Bolder type and a
/// close button alone were not enough (2026-10-18: "the little x next to it is
/// too subtle"), so it sits on a tinted card with an accent line along its
/// foot, and the other tabs' names step back to secondary. A tint, not the
/// panes' own colour: on macOS 26 the bar is that colour too, and a card in
/// it vanished (photographed, light and dark). With the keyboard in the tab
/// strip (⌘↑) the active tab fills with the accent colour instead.
struct TabChip: View {
    let title: String
    let hasTerminal: Bool
    let isActive: Bool
    /// the tab strip has the keyboard
    let barFocused: Bool
    let showClose: Bool
    var onClose: () -> Void = {}

    @Environment(\.uiZoom) private var zoom

    private var highlighted: Bool { isActive && barFocused }

    private var ink: AnyShapeStyle {
        if highlighted { return AnyShapeStyle(.white) }
        return isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .uiFont(12, weight: isActive ? .semibold : .regular)
                .foregroundStyle(ink)
                .lineLimit(1)
            if hasTerminal {
                Image(systemName: "terminal")
                    .uiFont(9)
                    .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
            if showClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .uiFont(8, weight: .bold)
                        .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help("Close Tab (⌘W)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background { card }
    }

    @ViewBuilder
    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        if highlighted {
            shape.fill(Color.accentColor)
        } else if isActive {
            shape.fill(Color.primary.opacity(0.09))
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 2.5 * zoom)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 1)
                }
        }
    }
}
