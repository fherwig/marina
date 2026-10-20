import SwiftUI
import AppKit

// MARK: - The grid

/// A pane's folder as tiles (View ▸ Toggle Tiles, ⌘4): each file's picture,
/// the name under it, as many across as the tile size (the slider in the path
/// bar, ⌥⌘+ / ⌥⌘−) lets fit. The cursor, the marks and the selection they
/// make are TileSelection's; `pane.selection` always holds that selection,
/// so the menus, the viewer and Quick Look need nothing new.
extension FilePaneView {
    var tiles: some View {
        let side = CGFloat(tileSize)
        let spacing: CGFloat = 8
        let inset: CGFloat = 10
        // a tile is the picture's box plus its padding
        let cell = side + 12
        // Read here, out of the pane, and handed in as values. Read inside
        // the GeometryReader they changed nothing on screen: ⌘A selected
        // all 17 tiles (the path bar said so) and the tiles showed none of
        // it until the size changed (photographed). SwiftUI runs that
        // closure again only when what it captured is different, and the
        // pane is the same object however its selection changes.
        let entries = pane.entries
        let looks = TileLooks(selection: pane.selection,
                              ring: tileState.marks.isEmpty ? nil : tileState.cursor,
                              active: focus.wrappedValue == .pane(pane.id))
        return GeometryReader { geo in
            let columns = max(1, Int((geo.size.width - 2 * inset + spacing) / (cell + spacing)))
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
                                             count: columns),
                              spacing: spacing + 6) {
                        ForEach(entries) { entry in
                            tile(entry, side: side, looks: looks).id(entry.id)
                        }
                    }
                    .padding(inset)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                    // a click between tiles: this pane has the keyboard, the
                    // marks go
                    .background(Color.clear.contentShape(Rectangle()).onTapGesture { clickedBetweenTiles() })
                }
                .onChange(of: columns, initial: true) { _, count in tileColumns = count }
                .onChange(of: tileScrollGen) { _, _ in
                    if let id = tileState.cursor { proxy.scrollTo(id) }
                }
            }
        }
        .background(TileDragSource(hover: tileHover) { id in urlsToDrag(startingAt: id) })
        .contextMenu { contextMenuItems(for: []) }
        .focusable()
        .focusEffectDisabled()
        .focused(focus, equals: .pane(pane.id))
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end]) { press in
            tileKey(press)
        }
        .onKeyPress(.return) { openSelection(); return .handled }
        .onKeyPress(.space) { changeTiles { $0.toggleMark() }; return .handled }
        .onKeyPress(.escape) {
            guard !tileState.marks.isEmpty else { return .ignored }
            changeTiles { $0.marks = [] }
            return .handled
        }
        .onKeyPress(characters: TypeAhead.characters, phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
                  !press.characters.isEmpty else { return .ignored }
            let current = tileState.cursor.flatMap { id in pane.entries.firstIndex { $0.id == id } }
            if let target = typeAhead.next(press.characters, in: pane.entries.map(\.name), from: current) {
                changeTiles(scroll: true) { $0.moveTo(target, order: tileOrder, extend: false) }
            }
            return .handled
        }
        .onKeyPress(keys: [.delete], phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            pane.goUp()
            return .handled
        }
        .onKeyPress(.tab) {
            guard tab.isDual else { return .ignored }
            tab.switchPane()
            return .handled
        }
        .onAppear { adoptSelection(scroll: true) }
    }

    // MARK: One tile

    @ViewBuilder
    private func tile(_ entry: FileEntry, side: CGFloat, looks: TileLooks) -> some View {
        let view = TileView(entry: entry, side: side,
                            selected: looks.selection.contains(entry.id),
                            cursor: entry.id == looks.ring,
                            active: looks.active)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { tileHover.id = entry.id } else if tileHover.id == entry.id { tileHover.id = nil }
            }
            .gesture(TapGesture(count: 2).onEnded { clickedTile(entry); openSelection() })
            .simultaneousGesture(TapGesture().onEnded { clickedTile(entry) })
            .contextMenu {
                contextMenuItems(for: pane.selection.contains(entry.id) ? pane.selection : [entry.id])
            }
        if entry.isNavigable {
            FolderDropTarget(folder: entry.url) { view }
        } else {
            view
        }
    }

    // MARK: Cursor and marks

    private var tileOrder: [String] { pane.entries.map(\.id) }

    /// Change the cursor or marks, and the pane's selection with them.
    private func changeTiles(scroll: Bool = false, _ change: (inout TileSelection) -> Void) {
        change(&tileState)
        let selection = tileState.selection
        if pane.selection != selection { pane.selection = selection }
        if scroll { tileScrollGen += 1 }
    }

    /// The selection changed from outside: put the cursor and marks there.
    func adoptSelection(scroll: Bool = false) {
        tileState.adopt(pane.selection, order: tileOrder)
        if scroll { tileScrollGen += 1 }
    }

    private func tileKey(_ press: KeyPress) -> KeyPress.Result {
        let modifiers = press.modifiers
        if modifiers.contains(.command) {
            // ⌘← / ⌘→ move between panes and the sidebar, as from the list;
            // ⌘↑ / ⌘↓ are menu items and never get here
            if press.key == .leftArrow, !modifiers.contains(.option) {
                if tab.isDual && paneIndex == 1 {
                    tab.activePaneIndex = 0
                    app.requestFocus(.pane(tab.panes[0].id))
                } else {
                    app.focusSidebar()
                }
                return .handled
            }
            if press.key == .rightArrow {
                if tab.isDual && paneIndex == 0 {
                    tab.activePaneIndex = 1
                    app.requestFocus(.pane(tab.panes[1].id))
                }
                return .handled
            }
            return .ignored
        }
        guard modifiers.isDisjoint(with: [.option, .control]) else { return .ignored }
        let move: TileSelection.Move
        switch press.key {
        case .leftArrow: move = .left
        case .rightArrow: move = .right
        case .upArrow: move = .up
        case .downArrow: move = .down
        case .home: move = .first
        default: move = .last
        }
        changeTiles(scroll: true) {
            $0.move(move, order: tileOrder, columns: tileColumns, extend: modifiers.contains(.shift))
        }
        return .handled
    }

    // MARK: Mouse

    private func takeKeyboard() {
        tab.activePaneIndex = paneIndex
        if focus.wrappedValue != .pane(pane.id) { app.requestFocus(.pane(pane.id)) }
    }

    private func clickedTile(_ entry: FileEntry) {
        takeKeyboard()
        let flags = NSEvent.modifierFlags
        changeTiles {
            $0.click(entry.id, order: tileOrder, command: flags.contains(.command), shift: flags.contains(.shift))
        }
    }

    private func clickedBetweenTiles() {
        takeKeyboard()
        changeTiles { $0.marks = [] }
    }

    /// A drag that starts on a tile carries the selection when the tile is
    /// in it, and otherwise that tile alone, which becomes the selection.
    private func urlsToDrag(startingAt id: String) -> [URL] {
        guard pane.entries.contains(where: { $0.id == id }) else { return [] }
        changeTiles { $0.dragStarts(on: id) }
        return pane.selectedEntries.map(\.url)
    }

    /// Quick Look's ↑ / ↓, in tiles: the tile before or after.
    func tileStep(by delta: Int) {
        changeTiles(scroll: true) {
            $0.move(delta > 0 ? .right : .left, order: tileOrder, columns: tileColumns, extend: false)
        }
    }
}

/// What the tiles show of the selection and the keyboard.
struct TileLooks: Equatable {
    let selection: Set<String>
    /// the cursor's tile, ringed while tiles are marked
    let ring: String?
    /// the pane has the keyboard
    let active: Bool
}

/// Which tile the mouse is over. A plain reference, so hovering redraws
/// nothing; the drag source reads it when a drag begins.
final class TileHover: ObservableObject {
    var id: String?
}

// MARK: - A tile

struct TileView: View {
    let entry: FileEntry
    /// the picture's box, in points
    let side: CGFloat
    let selected: Bool
    /// the cursor, drawn as a ring while some tiles are marked
    let cursor: Bool
    /// the pane has the keyboard: the selection in the accent colour
    let active: Bool

    @State private var thumbnail: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        let picture = thumbnail ?? Thumbnails.shared.cached(entry, side: side)
        VStack(spacing: 4) {
            Group {
                if let picture {
                    Image(nsImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    // the icon until Quick Look answers, smaller than a picture
                    Image(nsImage: Thumbnails.shared.icon(for: entry))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side * 0.6, height: side * 0.6)
                }
            }
            .frame(width: side, height: side)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(selected ? 0.1 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(cursor ? 1 : 0), lineWidth: 2)
            )
            Text(entry.name)
                .uiFont(12)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .foregroundStyle(selected && active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selected ? (active ? AnyShapeStyle(Color.accentColor)
                                                 : AnyShapeStyle(Color.secondary.opacity(0.3)))
                                       : AnyShapeStyle(Color.clear))
                )
                .frame(maxWidth: side + 12)
        }
        .help(entry.name)
        .task(id: "\(entry.id)|\(entry.modified?.timeIntervalSince1970 ?? 0)|\(Thumbnails.step(for: side))") {
            if let image = await Thumbnails.shared.load(entry, side: side, scale: scale) {
                thumbnail = image
            }
        }
    }
}

// MARK: - Dragging tiles out

/// Starts a drag of every selected file when the mouse drags off a tile.
///
/// SwiftUI's `.onDrag` gives one item provider, which carries one file, and a
/// drag of a marked set has to carry them all. So the drag is AppKit's: a
/// local monitor sees the mouse go down over a tile (TileHover) and, once it
/// has moved a few points, begins a dragging session with one item per file,
/// the way a table's rows go. The click itself is left to the tiles'.
struct TileDragSource: NSViewRepresentable {
    let hover: TileHover
    let urls: (String) -> [URL]

    func makeNSView(context: Context) -> SourceView {
        let view = SourceView()
        view.hover = hover
        view.urls = urls
        return view
    }

    func updateNSView(_ view: SourceView, context: Context) {
        view.hover = hover
        view.urls = urls
    }

    final class SourceView: NSView, NSDraggingSource {
        var hover: TileHover?
        var urls: ((String) -> [URL])?
        private var monitor: Any?
        private var down: (event: NSEvent, tile: String)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                let swallow = MainActor.assumeIsolated { self?.startsDrag(event) ?? false }
                return swallow ? nil : event
            }
        }

        /// Whether this event began a drag, and so is ours.
        private func startsDrag(_ event: NSEvent) -> Bool {
            guard event.window === window else { return false }
            switch event.type {
            case .leftMouseDown:
                let point = convert(event.locationInWindow, from: nil)
                down = bounds.contains(point) ? hover?.id.map { (event, $0) } : nil
            case .leftMouseDragged:
                guard let start = down else { return false }
                let a = start.event.locationInWindow, b = event.locationInWindow
                guard hypot(b.x - a.x, b.y - a.y) > 4 else { return false }
                down = nil
                let files = urls?(start.tile) ?? []
                guard !files.isEmpty else { return false }
                let at = convert(a, from: nil)
                let items = files.enumerated().map { i, url in
                    let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    let offset = CGFloat(min(i, 5)) * 4
                    item.setDraggingFrame(NSRect(x: at.x - 24 + offset, y: at.y - 24 - offset, width: 48, height: 48),
                                          contents: icon)
                    return item
                }
                beginDraggingSession(with: items, event: start.event, source: self)
                return true
            default:
                down = nil
            }
            return false
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // copied where it lands: a drag out of Marina never takes files
            // away from here
            [.copy, .generic]
        }
    }
}
