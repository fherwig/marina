import SwiftUI
import AppKit

/// Favourites sidebar with fully deterministic keyboard handling: the view owns
/// the selection index and handles arrow keys itself (SwiftUI List keyboard
/// focus in sidebars is unreliable). Every selection move navigates the active
/// pane immediately, Finder-style.
///
/// Favourites may be folders or files: folders navigate the pane, files open
/// in their default app. They live in sections the user makes and names; each
/// section folds away with its disclosure triangle, or with ← / →. Items are
/// added by drag & drop onto the sidebar or with ⌥⌘← from a pane, and
/// reordered — within a section or into another one — by dragging them.
struct SidebarView: View {
    @EnvironmentObject var app: AppState
    var focus: FocusState<FocusTarget?>.Binding
    /// Index into `rows`, not into the flat favourites list: headers are rows
    /// too, and a folded section hides its contents.
    @State private var index = 0
    @State private var rowFrames: [Int: RowGeometry] = [:]
    @State private var width: CGFloat = 0
    @State private var dropTargeted = false
    @AppStorage("marina.claudeSectionCollapsed") private var claudeCollapsed = false
    @AppStorage("marina.volumesSectionCollapsed") private var volumesCollapsed = false
    @State private var typeAhead = TypeAhead()
    @State private var drag: DragState?
    @State private var target: DropTarget?

    /// Rows and drag locations are measured in here, so they can be compared.
    private static let space = "marina.sidebar"

    private var isFocused: Bool { focus.wrappedValue == .sidebar }
    private var store: FavouritesStore { FavouritesStore.shared }

    // MARK: - Rows

    /// One line in the sidebar: a section header, or a favourite inside an
    /// unfolded section.
    private enum Row: Identifiable, Equatable {
        case header(FavouriteSection)
        case item(section: UUID, position: Int, url: URL)
        case claudeHeader
        case claude(ClaudeSession)
        case volumesHeader
        case volume(Volume)

        var id: String {
            switch self {
            case .header(let s): return "h:\(s.id.uuidString)"
            case .item(let s, let p, let url): return "i:\(s.uuidString):\(p):\(url.path)"
            case .claudeHeader: return "claude:header"
            case .claude(let session): return "claude:\(session.pid)"
            case .volumesHeader: return "volumes:header"
            case .volume(let volume): return "volume:\(volume.id)"
            }
        }

        /// The favourites section this row belongs to — nil for the generated
        /// Claude rows, which nothing can be dropped into or reordered within.
        var favouriteSection: UUID? {
            switch self {
            case .header(let s): return s.id
            case .item(let s, _, _): return s
            case .claudeHeader, .claude, .volumesHeader, .volume: return nil
            }
        }
    }

    private var rows: [Row] {
        var out: [Row] = []
        for section in app.favouriteSections {
            out.append(.header(section))
            guard !section.collapsed else { continue }
            for (i, url) in section.urls.enumerated() {
                out.append(.item(section: section.id, position: i, url: url))
            }
        }
        out.append(.volumesHeader)
        if !volumesCollapsed {
            for volume in app.volumes { out.append(.volume(volume)) }
        }
        out.append(.claudeHeader)
        if !claudeCollapsed {
            for session in app.claudeSessions { out.append(.claude(session)) }
        }
        return out
    }

    /// The keyboard stops on favourites, and on headers that stand alone — a
    /// folded section is a single row, and an empty one still has to be
    /// reachable to be renamed or unfolded.
    private func selectable(_ row: Row) -> Bool {
        switch row {
        case .item, .claude, .volume: return true
        case .header(let s): return s.collapsed || s.urls.isEmpty
        case .claudeHeader: return claudeCollapsed || app.claudeSessions.isEmpty
        case .volumesHeader: return volumesCollapsed || app.volumes.isEmpty
        }
    }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        switch row {
                        case .header(let section):
                            header(at: i, section)
                        case .item(let sectionID, let position, let url):
                            item(at: i, section: sectionID, position: position, url: url)
                        case .claudeHeader:
                            claudeHeader(at: i)
                        case .claude(let session):
                            claudeRow(at: i, session)
                        case .volumesHeader:
                            volumesHeader(at: i)
                        case .volume(let volume):
                            volumeRow(at: i, volume)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("New Section…") { app.newFavouriteSection() }
                }
            }
            .coordinateSpace(.named(Self.space))
            .background(GeometryReader { g in
                Color.clear.onAppear { width = g.size.width }
                    .onChange(of: g.size.width) { _, w in width = w }
            })
            .focusable()
            .focusEffectDisabled()
            .focused(focus, equals: .sidebar)
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.return) { commit(); return .handled }
            .onKeyPress(.space) { showActionMenu(); return .handled }
            .onKeyPress(.leftArrow) { fold(); return .handled }
            .onKeyPress(characters: TypeAhead.characters, phases: .down) { press in
                guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
                      !press.characters.isEmpty else { return .ignored }
                typeSelect(press.characters)
                return .handled
            }
            .onKeyPress(keys: [.rightArrow], phases: .down) { press in
                if press.modifiers.contains(.command) {
                    // ⌘→: just return focus — the undo for an accidental ⌘←,
                    // the pane keeps whatever folder it was showing
                    if let tab = app.activeTab {
                        app.requestFocus(.pane(tab.activePane.id))
                    }
                } else {
                    // plain →: unfold a folded section, otherwise commit to the
                    // selected favourite
                    commit()
                }
                return .handled
            }
            .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }
            // drag items (files or folders) out of a pane or Finder onto the
            // sidebar to add them — nothing is moved on disk
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                for url in files { app.addFavourite(url) }
                target = nil
                return true
            } isTargeted: { dropTargeted = $0 }
            .background(dropTargeted ? AnyShapeStyle(Color.accentColor.opacity(0.1)) : AnyShapeStyle(.clear))
            .onChange(of: focus.wrappedValue) { _, newFocus in
                // arriving in the sidebar: highlight the current folder's favourite
                // if it is one, without navigating anywhere
                guard newFocus == .sidebar else { return }
                if let current = app.activePane?.directory.path,
                   let i = rows.firstIndex(where: {
                       if case .item(_, _, let url) = $0 { return url.path == current }
                       return false
                   }) {
                    index = i
                }
                normalise()
            }
            .onChange(of: rows.count) { _, _ in normalise() }
            .onAppear {
                app.refreshClaudeSessionsIfNeeded()
                app.refreshVolumesIfNeeded()
            }

            // Moving the selection does not scroll it into view on its own:
            // this is a ScrollView of rows we draw ourselves, not a List, so
            // nothing tracks the keyboard. Without it the selection walks off
            // the top or bottom edge and disappears.
            .onChange(of: index) { _, i in
                let all = rows
                guard all.indices.contains(i) else { return }
                // nil anchor: scroll the least amount that makes it visible
                proxy.scrollTo(all[i].id)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func header(at i: Int, _ section: FavouriteSection) -> some View {
        let selected = i == index && selectable(.header(section))
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(section.collapsed ? 0 : 90))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Text(section.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .padding(.top, i == 0 ? 0 : 6)
        .contentShape(Rectangle())
        .measured(at: i, space: Self.space)
        .insertionLine(insertionEdge(at: i))
        .onTapGesture {
            store.toggleCollapsed(section.id)
            index = rowIndex(ofHeader: section.id) ?? index
            normalise()
        }
        .dropDestination(for: URL.self) { urls, _ in
            drop(urls, section: section.id, at: section.collapsed ? section.urls.count : 0)
        } isTargeted: { hovering in
            target = hovering
                ? DropTarget(section: section.id, position: section.collapsed ? section.urls.count : 0)
                : nil
        }
        .contextMenu { sectionMenuItems(section) }
    }

    @ViewBuilder
    private func item(at i: Int, section sectionID: UUID, position: Int, url: URL) -> some View {
        let selected = i == index
        let dragged = drag?.row == i
        HStack(spacing: 7) {
            Image(systemName: symbol(for: url))
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(selected && isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
            Text(displayName(for: url))
                .font(.system(size: 13))
                .foregroundStyle(selected && isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            selected
                ? (isFocused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .opacity(dragged ? 0.35 : 1)
        .contentShape(Rectangle())
        .measured(at: i, space: Self.space)
        .insertionLine(insertionEdge(at: i))
        .onTapGesture {
            index = i
            openFavourite(url, focusPane: false)
        }
        // reorder by dragging: this stays inside the sidebar and never touches
        // the pasteboard, so a plain click still selects — a drag modifier
        // would take the mouse down away from the row
        .gesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    if drag == nil { drag = DragState(url: url, row: i) }
                    target = dropTarget(at: value.location)
                }
                .onEnded { _ in
                    if let moved = drag?.url, let t = target {
                        store.move(moved, toSection: t.section, at: t.position)
                        index = rowIndex(ofItem: moved) ?? index
                    }
                    drag = nil
                    target = nil
                }
        )
        .dropDestination(for: URL.self) { urls, _ in
            drop(urls, section: sectionID, at: position)
        } isTargeted: { hovering in
            target = hovering ? DropTarget(section: sectionID, position: position) : nil
        }
        .contextMenu { itemMenuItems(url, in: sectionID) }
    }

    // MARK: - Volumes

    /// Generated section: every mounted volume and cloud drive. No refresh
    /// button — mounting and unmounting announce themselves, so the list keeps
    /// itself current (see VolumesStore).
    @ViewBuilder
    private func volumesHeader(at i: Int) -> some View {
        let selected = i == index && selectable(.volumesHeader)
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(volumesCollapsed ? 0 : 90))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Text("Volumes")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .padding(.top, i == 0 ? 0 : 6)
        .contentShape(Rectangle())
        .measured(at: i, space: Self.space)
        .onTapGesture {
            volumesCollapsed.toggle()
            index = rows.firstIndex { $0 == .volumesHeader } ?? index
            normalise()
        }
        .contextMenu {
            Button(volumesCollapsed ? "Expand Section (→)" : "Collapse Section (←)") {
                volumesCollapsed.toggle()
            }
            Divider()
            Button("Refresh Volumes") { app.refreshVolumes() }
        }
    }

    @ViewBuilder
    private func volumeRow(at i: Int, _ volume: Volume) -> some View {
        let selected = i == index
        HStack(spacing: 7) {
            Image(systemName: volume.symbol)
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(selected && isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
            Text(volume.name)
                .font(.system(size: 13))
                .foregroundStyle(selected && isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .lineLimit(1)
            if let caption = volume.caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(selected && isFocused ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            selected
                ? (isFocused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .measured(at: i, space: Self.space)
        .help(volume.url.path)
        .onTapGesture {
            index = i
            openFavourite(volume.url, focusPane: false)
        }
        .contextMenu { volumeMenuItems(volume) }
    }

    @ViewBuilder
    private func volumeMenuItems(_ volume: Volume) -> some View {
        Button("Open") { openFavourite(volume.url, focusPane: true) }
        Button("Open in Second Pane") { app.activeTab?.openInSecondPane(volume.url) }
        Button("Open in New Tab") { app.newTab(at: volume.url) }
        Button("Open in Marina Terminal") { app.openInTerminal(volume.url) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([volume.url])
        }
        Divider()
        Button("Add to Sidebar") { app.addFavourite(volume.url) }
        if volume.ejectable {
            Button("Eject") { app.eject(volume) }
        }
        Button("Refresh Volumes") { app.refreshVolumes() }
    }

    // MARK: - Claude sessions

    /// Generated section: the folders of every Claude Code session running
    /// right now. It is a snapshot, so the header carries the button that
    /// takes a new one.
    @ViewBuilder
    private func claudeHeader(at i: Int) -> some View {
        let selected = i == index && selectable(.claudeHeader)
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(claudeCollapsed ? 0 : 90))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Text("Claude Sessions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                app.refreshClaudeSessions()
            } label: {
                if app.claudeSessionsScanning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12, height: 12)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Rescan for running Claude sessions")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .padding(.top, i == 0 ? 0 : 6)
        .contentShape(Rectangle())
        .measured(at: i, space: Self.space)
        .onTapGesture {
            claudeCollapsed.toggle()
            index = rows.firstIndex { $0 == .claudeHeader } ?? index
            normalise()
        }
        .contextMenu {
            Button(claudeCollapsed ? "Expand Section (→)" : "Collapse Section (←)") {
                claudeCollapsed.toggle()
            }
            Divider()
            Button("Refresh Claude Sessions (⇧⌥⌘R)") { app.refreshClaudeSessions() }
        }
    }

    @ViewBuilder
    private func claudeRow(at i: Int, _ session: ClaudeSession) -> some View {
        let selected = i == index
        HStack(spacing: 7) {
            // a pane in a tmux session, or a bare terminal window
            Image(systemName: session.isBare ? "terminal" : "rectangle.split.2x1")
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(selected && isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
            Text(session.name)
                .font(.system(size: 13))
                .foregroundStyle(selected && isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .lineLimit(1)
            if let caption = session.caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(selected && isFocused ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            selected
                ? (isFocused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .measured(at: i, space: Self.space)
        .help(session.directory.path)
        .onTapGesture {
            index = i
            openFavourite(session.directory, focusPane: false)
        }
        .contextMenu {
            Button("Open") { openFavourite(session.directory, focusPane: true) }
            Button("Open in Second Pane") { app.activeTab?.openInSecondPane(session.directory) }
            Button("Open in New Tab") { app.newTab(at: session.directory) }
            Button("Open in Marina Terminal") { app.openInTerminal(session.directory) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([session.directory])
            }
            Divider()
            Button("Add to Sidebar") { app.addFavourite(session.directory) }
            Button("Refresh Claude Sessions") { app.refreshClaudeSessions() }
        }
    }

    // MARK: - Menus

    @ViewBuilder
    private func itemMenuItems(_ url: URL, in sectionID: UUID) -> some View {
        if isNavigableDir(url) {
            Button("Open") { openFavourite(url, focusPane: true) }
            Button("Open in Second Pane") { app.activeTab?.openInSecondPane(url) }
            Button("Open in New Tab") { app.newTab(at: url) }
            Button("Open in Marina Terminal") { app.openInTerminal(url) }
        } else {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        Menu("Move to Section") {
            ForEach(app.favouriteSections.filter { $0.id != sectionID }) { section in
                Button(section.name) {
                    store.move(url, toSection: section.id, at: section.urls.count)
                    index = rowIndex(ofItem: url) ?? index
                }
            }
            Divider()
            Button("New Section…") { app.newFavouriteSection() }
        }
        Button("Remove from Sidebar") { app.removeFavourite(url) }
    }

    @ViewBuilder
    private func sectionMenuItems(_ section: FavouriteSection) -> some View {
        Button(section.collapsed ? "Expand Section (→)" : "Collapse Section (←)") {
            store.toggleCollapsed(section.id)
        }
        Divider()
        Button("New Section… (⇧⌥⌘N)") { app.newFavouriteSection() }
        Button("Rename Section…") { app.renameFavouriteSection(section.id) }
        Button("Delete Section") { store.deleteSection(section.id) }
            .disabled(app.favouriteSections.count < 2)
        Divider()
        Button("Move Section Up") { store.moveSection(section.id, by: -1) }
        Button("Move Section Down") { store.moveSection(section.id, by: 1) }
    }

    /// Space — the row's action menu as a real NSMenu at the selected row
    /// (arrow keys + Return work natively, Esc closes).
    private func showActionMenu() {
        let all = rows
        guard all.indices.contains(index) else { return }
        let menu = NSMenu()

        func add(_ title: String, to parent: NSMenu = menu, _ action: @escaping () -> Void) {
            let proxy = MenuAction(action)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
            item.target = proxy
            item.representedObject = proxy  // NSMenuItem.target is weak; retain the proxy here
            parent.addItem(item)
        }

        switch all[index] {
        case .header(let section):
            add(section.collapsed ? "Expand Section" : "Collapse Section") { store.toggleCollapsed(section.id) }
            menu.addItem(.separator())
            add("New Section…") { app.newFavouriteSection() }
            add("Rename Section…") { app.renameFavouriteSection(section.id) }
            if app.favouriteSections.count > 1 {
                add("Delete Section") { store.deleteSection(section.id) }
            }
            menu.addItem(.separator())
            add("Move Section Up") { store.moveSection(section.id, by: -1) }
            add("Move Section Down") { store.moveSection(section.id, by: 1) }

        case .item(let sectionID, _, let url):
            if isNavigableDir(url) {
                add("Open") { openFavourite(url, focusPane: true) }
                add("Open in Second Pane") { app.activeTab?.openInSecondPane(url) }
                add("Open in New Tab") { app.newTab(at: url) }
                add("Open in Marina Terminal") { app.openInTerminal(url) }
            } else {
                add("Open") { NSWorkspace.shared.open(url) }
                add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            menu.addItem(.separator())
            let others = app.favouriteSections.filter { $0.id != sectionID }
            if !others.isEmpty {
                let submenu = NSMenu()
                for section in others {
                    add(section.name, to: submenu) {
                        store.move(url, toSection: section.id, at: section.urls.count)
                        index = rowIndex(ofItem: url) ?? index
                    }
                }
                let holder = NSMenuItem(title: "Move to Section", action: nil, keyEquivalent: "")
                holder.submenu = submenu
                menu.addItem(holder)
            }
            add("New Section…") { app.newFavouriteSection() }
            menu.addItem(.separator())
            add("Remove from Sidebar") { app.removeFavourite(url) }

        case .claudeHeader:
            add(claudeCollapsed ? "Expand Section" : "Collapse Section") { claudeCollapsed.toggle() }
            menu.addItem(.separator())
            add("Refresh Claude Sessions") { app.refreshClaudeSessions() }

        case .volumesHeader:
            add(volumesCollapsed ? "Expand Section" : "Collapse Section") { volumesCollapsed.toggle() }
            menu.addItem(.separator())
            add("Refresh Volumes") { app.refreshVolumes() }

        case .volume(let volume):
            let url = volume.url
            add("Open") { openFavourite(url, focusPane: true) }
            add("Open in Second Pane") { app.activeTab?.openInSecondPane(url) }
            add("Open in New Tab") { app.newTab(at: url) }
            add("Open in Marina Terminal") { app.openInTerminal(url) }
            add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            menu.addItem(.separator())
            add("Add to Sidebar") { app.addFavourite(url) }
            if volume.ejectable { add("Eject") { app.eject(volume) } }

        case .claude(let session):
            let url = session.directory
            add("Open") { openFavourite(url, focusPane: true) }
            add("Open in Second Pane") { app.activeTab?.openInSecondPane(url) }
            add("Open in New Tab") { app.newTab(at: url) }
            add("Open in Marina Terminal") { app.openInTerminal(url) }
            add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            menu.addItem(.separator())
            add("Add to Sidebar") { app.addFavourite(url) }
            add("Refresh Claude Sessions") { app.refreshClaudeSessions() }
        }

        guard let content = NSApp.keyWindow?.contentView else { return }
        let frame = rowFrames[index]?.global ?? .zero
        // SwiftUI global space is top-left origin; AppKit's is bottom-left
        let point = NSPoint(x: frame.minX + 6, y: content.bounds.height - frame.maxY)
        menu.popUp(positioning: menu.items.first, at: point, in: content)
    }

    // MARK: - Keyboard

    private func move(_ delta: Int) {
        let all = rows
        guard !all.isEmpty else { return }
        var i = index
        while true {
            i += delta
            guard all.indices.contains(i) else { return }   // at the end: stay put
            if selectable(all[i]) { break }
        }
        index = i
        // folders navigate as you move; files just get selected — opening
        // an app on every arrow press would be chaos
        if let url = navigableURL(of: all[i]) { navigate(to: url) }
    }

    /// Return / → — unfold a folded section, or commit to the favourite;
    /// folders also hand focus back to the file pane.
    private func commit() {
        let all = rows
        guard all.indices.contains(index) else { return }
        switch all[index] {
        case .header(let section):
            guard section.collapsed else { return }
            store.setCollapsed(section.id, false)
            index = rowIndex(ofItem: section.urls.first) ?? index
        case .item(_, _, let url):
            openFavourite(url, focusPane: true)
        case .claudeHeader:
            guard claudeCollapsed else { return }
            claudeCollapsed = false
            normalise()
        case .claude(let session):
            openFavourite(session.directory, focusPane: true)
        case .volumesHeader:
            guard volumesCollapsed else { return }
            volumesCollapsed = false
            normalise()
        case .volume(let volume):
            openFavourite(volume.url, focusPane: true)
        }
    }

    /// The folder an arrow key landing on this row should take the pane to.
    private func navigableURL(of row: Row) -> URL? {
        switch row {
        case .item(_, _, let url): return isNavigableDir(url) ? url : nil
        case .claude(let session): return isNavigableDir(session.directory) ? session.directory : nil
        case .volume(let volume): return isNavigableDir(volume.url) ? volume.url : nil
        case .header, .claudeHeader, .volumesHeader: return nil
        }
    }

    /// ← — fold the section the selection is in; the header takes its place.
    private func fold() {
        let all = rows
        guard all.indices.contains(index) else { return }
        if let sectionID = all[index].favouriteSection {
            store.setCollapsed(sectionID, true)
            index = rowIndex(ofHeader: sectionID) ?? index
        } else if case .volume = all[index] {
            volumesCollapsed = true
            index = rows.firstIndex { $0 == .volumesHeader } ?? index
        } else if case .volumesHeader = all[index] {
            volumesCollapsed = true
        } else {
            claudeCollapsed = true
            index = rows.firstIndex { $0 == .claudeHeader } ?? index
        }
        normalise()
    }

    /// Jump to the next row whose name starts with what was typed; typing the
    /// same letter again steps to the one after that. Only what is on screen
    /// counts — a folded section's contents are not searched, which is what
    /// folding it away was for.
    private func typeSelect(_ typed: String) {
        let all = rows
        let names = all.map { row -> String in
            switch row {
            case .item(_, _, let url): return displayName(for: url)
            case .claude(let session): return session.name
            case .volume(let volume): return volume.name
            case .header, .claudeHeader, .volumesHeader: return ""   // never a target
            }
        }
        guard let target = typeAhead.next(typed, in: names, from: index) else { return }
        index = target
        // same as arrowing onto it: folders take the pane with them
        if let url = navigableURL(of: all[target]) { navigate(to: url) }
    }

    /// Keep the selection on a row the keyboard is allowed to sit on.
    private func normalise() {
        let all = rows
        guard !all.isEmpty else { index = 0; return }
        if all.indices.contains(index), selectable(all[index]) { return }
        let below = all.indices.first { $0 >= index && selectable(all[$0]) }
        let above = all.indices.reversed().first { $0 <= index && selectable(all[$0]) }
        index = below ?? above ?? 0
    }

    private func rowIndex(ofHeader id: UUID) -> Int? {
        rows.firstIndex { if case .header(let s) = $0 { return s.id == id }; return false }
    }

    private func rowIndex(ofItem url: URL?) -> Int? {
        guard let path = url?.standardizedFileURL.path else { return nil }
        return rows.firstIndex { if case .item(_, _, let u) = $0 { return u.path == path }; return false }
    }

    // MARK: - Actions

    /// Click / Return / → on a favourite: folders navigate the active pane,
    /// files (and app bundles) open in their default app.
    private func openFavourite(_ url: URL, focusPane: Bool) {
        if isNavigableDir(url) {
            navigate(to: url)
            if focusPane, let tab = app.activeTab {
                app.requestFocus(.pane(tab.activePane.id))
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Navigate the active pane but keep focus here in the sidebar.
    private func navigate(to url: URL) {
        guard let tab = app.activeTab else {
            app.newTab(at: url)
            return
        }
        tab.activePane.navigate(to: url)
    }

    // MARK: - Dragging

    private struct DragState: Equatable {
        let url: URL
        /// Row the drag started on, so it can be shown lifted out of the list.
        let row: Int
    }

    private struct DropTarget: Equatable {
        let section: UUID
        let position: Int
    }

    /// Where a drop at this point would land: the nearest row decides, so the
    /// gaps between rows and between sections are never dead.
    private func dropTarget(at point: CGPoint) -> DropTarget? {
        // dragged well clear of the sidebar — nothing moves
        guard point.x > -24, width == 0 || point.x < width + 24 else { return nil }
        let all = rows
        // the Claude and Volumes rows are generated, so nothing lands in or
        // between them
        let nearest = all.indices
            .filter { all[$0].favouriteSection != nil }
            .compactMap { i -> (Int, CGRect)? in rowFrames[i].map { (i, $0.local) } }
            .min { verticalDistance($0.1, point) < verticalDistance($1.1, point) }
        guard let (i, frame) = nearest else { return nil }
        switch all[i] {
        case .header(let section):
            return DropTarget(section: section.id, position: section.collapsed ? section.urls.count : 0)
        case .item(let sectionID, let position, _):
            return DropTarget(section: sectionID, position: point.y > frame.midY ? position + 1 : position)
        case .claudeHeader, .claude, .volumesHeader, .volume:
            return nil
        }
    }

    private func verticalDistance(_ frame: CGRect, _ point: CGPoint) -> CGFloat {
        if point.y < frame.minY { return frame.minY - point.y }
        if point.y > frame.maxY { return point.y - frame.maxY }
        return 0
    }

    /// Which edge of row `i` the insertion line belongs on, if any.
    private func insertionEdge(at i: Int) -> Bool? {
        guard let t = target else { return nil }
        let all = rows
        if let exact = all.firstIndex(where: {
            if case .item(let s, let p, _) = $0 { return s == t.section && p == t.position }
            return false
        }) {
            return exact == i ? true : nil
        }
        // past the last visible row of that section — its header when the
        // section is folded or empty, otherwise its last favourite
        guard let last = all.lastIndex(where: { $0.favouriteSection == t.section }) else { return nil }
        return last == i ? false : nil
    }

    /// A drop from outside: files and folders become favourites at that spot.
    private func drop(_ urls: [URL], section: UUID, at position: Int) -> Bool {
        let files = urls.filter(\.isFileURL)
        target = nil
        guard !files.isEmpty else { return false }
        var at = position
        for url in files {
            store.add(url, toSection: section, at: at)
            at += 1
        }
        return true
    }

    // MARK: - Helpers

    /// Folders you can navigate into; packages (.app …) count as files. A
    /// symlink reports itself, not its target, so resolve it first — otherwise
    /// a favourite like "~/OneDrive - University of Victoria" looks like a file
    /// and gets handed to Finder instead of opening in the pane.
    private func isNavigableDir(_ url: URL) -> Bool {
        let rv = try? PaneState.resolved(url).resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return (rv?.isDirectory ?? false) && !(rv?.isPackage ?? false)
    }

    private func displayName(for url: URL) -> String {
        if url.path == NSHomeDirectory() { return "Home" }
        let name = url.lastPathComponent
        return name.isEmpty ? "/" : name
    }

    private func symbol(for url: URL) -> String {
        if url.path == NSHomeDirectory() { return "house" }
        if !isNavigableDir(url) {
            return url.pathExtension == "app" ? "app.dashed" : "doc"
        }
        switch url.lastPathComponent {
        case "Desktop": return "display"
        case "Documents": return "doc"
        case "Downloads": return "arrow.down.circle"
        case "Applications": return "square.grid.3x3"
        default: return "folder"
        }
    }
}

/// Closure target for programmatic NSMenu items.
private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// Row geometry in two spaces: window coordinates to anchor the Space action
/// menu, sidebar coordinates to work out where a drag would drop.
struct RowGeometry: Equatable {
    var global: CGRect
    var local: CGRect
}

struct RowFrameKey: PreferenceKey {
    static let defaultValue: [Int: RowGeometry] = [:]
    static func reduce(value: inout [Int: RowGeometry], nextValue: () -> [Int: RowGeometry]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private extension View {
    func measured(at index: Int, space: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(
                key: RowFrameKey.self,
                value: [index: RowGeometry(global: g.frame(in: .global),
                                           local: g.frame(in: .named(space)))]
            )
        })
    }

    /// The drop line: above the row, below it, or not at all.
    func insertionLine(_ edge: Bool?) -> some View {
        overlay(alignment: .top) { if edge == true { InsertionBar() } }
            .overlay(alignment: .bottom) { if edge == false { InsertionBar() } }
    }
}

private struct InsertionBar: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 2)
    }
}
