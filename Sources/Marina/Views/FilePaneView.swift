import SwiftUI
import AppKit
import QuickLook

struct FilePaneView: View {
    @EnvironmentObject var app: AppState
    /// Not observed: every change to the tab — which pane is active, above
    /// all — would otherwise rebuild both file lists, cell by cell, and that
    /// is what made switching panes slow. Only the header shows tab state
    /// (see PaneHeader); everything else here reads it when an event runs.
    let tab: TabState
    @ObservedObject var pane: PaneState
    let paneIndex: Int
    var focus: FocusState<FocusTarget?>.Binding
    /// The terminal sits right under this pane, and its grip takes the place
    /// of the bottom bar.
    var terminalBelow = false

    @State var typeAhead = TypeAhead()
    /// A real AppKit view inside this pane, for anchoring ⌥⌘O's menu.
    @StateObject private var anchor = PaneAnchorBox()
    @Environment(\.uiZoom) private var zoom

    // The tile view's (TileGrid.swift): the cursor and marked tiles, how
    // many fit across, and a count bumped to scroll the cursor into view.
    @State var tileState = TileSelection()
    @State var tileColumns = 1
    @State var tileScrollGen = 0
    @StateObject var tileHover = TileHover()
    @AppStorage(Preferences.tileSizeKey) var tileSize = Preferences.defaultTileSize

    private var isActivePane: Bool {
        !tab.isDual || tab.activePaneIndex == paneIndex
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(tab: tab, pane: pane, paneIndex: paneIndex, activate: activateFromClick)
            Divider()
            folderView
            if !terminalBelow {
                Divider()
                statusBar
            }
        }
        // a click anywhere in the pane makes it the active one, there and then
        .background(PaneClickWatcher { [tab, paneIndex] in
            if tab.isDual, tab.activePaneIndex != paneIndex { tab.activePaneIndex = paneIndex }
        })
        // NB: no tap gesture over the table — a SwiftUI gesture layered on top
        // of the NSTableView behind Table swallows the click that would select
        // a row. Clicking a pane makes it active through the selection change
        // (see activateFromClick) and through the path bar's own tap.
    }

    // MARK: - Table

    private var table: some View {
        Table(of: FileEntry.self, selection: $pane.selection, sortOrder: $pane.sortOrder) {
            TableColumn("Name", value: \FileEntry.name) { (entry: FileEntry) in
                let cell = HStack(spacing: 6) {
                    Image(nsImage: IconCache.icon(for: entry))
                        .resizable()
                        .frame(width: 16 * zoom, height: 16 * zoom)
                    Text(entry.name)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // A folder's row is itself a place to drop: items let go over
                // it go INTO that folder, not into the one on screen. Only the
                // Name column, as in Finder's list view, and lit while hovered
                // so it is clear which folder will receive them. A drop
                // destination is not a drag source: it does not take the
                // mouse-down, so clicking to select still works. (Dragging
                // OUT is not done here — see the rows below.)
                if entry.isNavigable {
                    FolderDropTarget(folder: entry.url) { cell }
                } else {
                    cell
                }
            }
            TableColumn("Size", value: \FileEntry.sortSize) { (entry: FileEntry) in
                Text(entry.displaySize)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // wide enough for "209 bytes": at 70 it read "209 b…"
            .width(min: 60 * zoom, ideal: 84 * zoom, max: 110 * zoom)
            TableColumn("Modified", value: \FileEntry.sortDate) { (entry: FileEntry) in
                Text(entry.displayDate)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80 * zoom, ideal: 110 * zoom, max: 140 * zoom)
        } rows: {
            // Dragging OUT lives on the row, not on the Name cell. A cell-level
            // .onDrag takes the mouse-down away from the table, so it had to
            // be limited to rows already selected — and it could carry only
            // the one row it sat on. On the row, the TABLE starts the drag:
            // it keeps the mouse-down for selection, a whole multi-row
            // selection goes as a set, and an unselected row can be dragged
            // straight away, as in Finder.
            ForEach(pane.entries) { entry in
                TableRow(entry)
                    .itemProvider { NSItemProvider(object: entry.url as NSURL) }
            }
        }
        // the rows' text, which names no size of its own. The table fits its
        // rows to it, but stripes the empty space below them at its own row
        // height, which SwiftUI resets to this minimum on every update; at
        // 1.6× that was rows of 33pt over stripes of 24. 16 × zoom + 8 is the
        // row the text makes: 24pt at 1×, as before (all measured).
        .uiFont(13)
        .environment(\.defaultMinListRowHeight, (16 * zoom + 8).rounded())
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenuItems(for: ids)
        } primaryAction: { ids in
            open(ids: ids)
        }
        .focused(focus, equals: .pane(pane.id))
        // something outside the list chose a row (open -a Marina <file>):
        // bring it into view. onAppear covers a reveal into a brand-new tab,
        // which has already happened by the time this view exists.
        .onChange(of: pane.revealGen) { _, _ in scrollToSelectionSoon() }
        .onAppear { if pane.revealGen > 0 { scrollToSelectionSoon() } }
        .onKeyPress(.return) { openSelection(); return .handled }
        .onKeyPress(.space) { toggleQuickLook(); return .handled }
        // taken off the table, which otherwise runs AppKit's own type-select
        .onKeyPress(characters: TypeAhead.characters, phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
                  !press.characters.isEmpty else { return .ignored }
            typeSelect(press.characters)
            return .handled
        }
        .onKeyPress(keys: [.leftArrow], phases: .down) { press in
            if press.modifiers.contains(.command) {
                if press.modifiers.contains(.option) {
                    // ⌥⌘←: add the selection to the sidebar favourites
                    app.addSelectionToFavourites()
                    return .handled
                }
                // ⌘←: move focus left — right pane → left pane → sidebar
                if tab.isDual && paneIndex == 1 {
                    tab.activePaneIndex = 0
                    app.requestFocus(.pane(tab.panes[0].id))
                } else {
                    app.focusSidebar()
                }
                return .handled
            }
            pane.goUp()
            return .handled
        }
        .onKeyPress(keys: [.rightArrow], phases: .down) { press in
            if press.modifiers.contains(.command) {
                // ⌘→: move focus right — left pane → right pane
                if tab.isDual && paneIndex == 0 {
                    tab.activePaneIndex = 1
                    app.requestFocus(.pane(tab.panes[1].id))
                }
                return .handled
            }
            return descendIntoSelection()
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
    }

    // MARK: - List or tiles

    /// The folder as a list or as tiles (⌘4), and what both do alike.
    private var folderView: some View {
        Group {
            if pane.showsTiles { tiles } else { table }
        }
        // an unreadable folder and an empty one both show no rows; only this
        // says which happened
        .overlay {
            if let failure = pane.failure, pane.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "lock.slash")
                        .uiFont(22)
                        .foregroundStyle(.secondary)
                    Text(failure.message)
                        .uiFont(12)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if failure.needsPermission {
                        Text("Give Marina Full Disk Access in System Settings, then come back.")
                            .uiFont(11)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                        Button("Open Privacy Settings…") { AppState.openPrivacySettings() }
                            .controlSize(.small)
                    }
                }
                .padding(24)
                .frame(maxWidth: 320)
            }
        }
        .background(PaneAnchor(box: anchor))
        .onChange(of: app.openWithRequest) { _, request in
            guard request?.pane == pane.id else { return }
            // off the update: popUp runs its own event loop, and starting one
            // inside a SwiftUI view update is asking for it to be dropped
            DispatchQueue.main.async { showOpenWithMenu() }
        }
        .onChange(of: app.quickLookRequest) { _, request in
            guard request?.pane == pane.id else { return }
            toggleQuickLook()
        }
        .onChange(of: pane.revealGen) { _, _ in
            if pane.showsTiles { adoptSelection(scroll: true) }
        }
        // accept file drops from Finder or the other pane (copies into this folder)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            app.drop(files, into: pane.directory)
            return true
        }
        // selecting a row with the mouse is also how the mouse hands this pane
        // the keyboard — the reliable backup when focus got stuck elsewhere
        .onChange(of: pane.selection) { _, _ in
            if pane.showsTiles { adoptSelection() }
            activateFromClick()
            // an open Quick Look panel shows whatever is selected now
            QuickLook.shared.selectionChanged(in: pane)
        }
        .onAppear {
            // claim keyboard focus once the view exists, so the first
            // arrow press moves the selection instead of being eaten;
            // the second, later set catches tab switches where the table
            // is not yet ready to accept focus on the first attempt
            if isActivePane {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    claimFocus()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    // after a tab switch the focus value still holds the
                    // previous tab's pane id and must be replaced
                    if tab.activePaneIndex == paneIndex { claimFocus() }
                }
            }
        }
    }

    // MARK: - Status bar

    /// The strip along the bottom of the pane, when no terminal sits below it.
    /// It carries nothing — what used to live here says more up in the path
    /// bar, and a file count was not worth a row of chrome anywhere. With the
    /// terminal below, its grip (TerminalGrip) takes this place.
    private var statusBar: some View {
        Color.clear
            .frame(height: 8)
    }

    // MARK: - Open With

    /// ⌥⌘O — a real NSMenu of the applications that claim the selection, so
    /// arrow keys and Return work in it and Esc closes it. Anchored to the
    /// pane rather than the row: SwiftUI's Table does not hand out row frames,
    /// and a menu that appears at the pane you are working in is no worse.
    private func showOpenWithMenu() {
        let urls = pane.selectedEntries.map(\.url)
        guard !urls.isEmpty else { return }
        let apps = AppState.applications(opening: urls)
        guard !apps.isEmpty else {
            app.errorMessage = "No application opens \(urls[0].lastPathComponent)"
            return
        }

        let menu = NSMenu()
        for (i, application) in apps.enumerated() {
            let proxy = OpenWithAction { app.open(urls, with: application) }
            let item = NSMenuItem(title: AppState.appName(application),
                                  action: #selector(OpenWithAction.fire),
                                  keyEquivalent: "")
            item.target = proxy
            item.representedObject = proxy  // NSMenuItem.target is weak
            let icon = NSWorkspace.shared.icon(forFile: application.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
            // the default application leads, and is fenced off from the rest
            if i == 0, apps.count > 1 { menu.addItem(.separator()) }
        }

        guard let host = anchor.view else { return }
        // the pane's own view, so there is no window to find and no top-left
        // to bottom-left flip: just below the top of the file list
        let point = NSPoint(x: 12, y: host.bounds.height - 8)
        menu.popUp(positioning: menu.items.first, at: point, in: host)
    }

    // MARK: - Type to select

    /// Keys are taken off the table, which otherwise runs AppKit's own
    /// type-select — see TypeAhead for why that was no good.
    private func typeSelect(_ typed: String) {
        let current = pane.selection.first.flatMap { id in
            pane.entries.firstIndex { $0.id == id }
        }
        guard let target = typeAhead.next(typed, in: pane.entries.map(\.name), from: current) else { return }
        pane.selection = [pane.entries[target].id]
        scrollRowToVisible(target)
    }

    /// Setting `selection` does not scroll: arrow keys move the row AppKit
    /// already knows about, so it scrolls itself, but a jump we make from
    /// outside leaves the selected row wherever it was — off screen, if the
    /// match is further down than the visible window. There is no SwiftUI
    /// hook for this on `Table` (`ScrollViewReader` does not reach its rows),
    /// so we find the `NSTableView` behind it and ask AppKit directly.
    /// Twice, as with `claimFocus`: a new tab's table is not laid out on the
    /// first pass, and scrolling a table with no rows yet does nothing.
    private func scrollToSelectionSoon() {
        DebugLog.open("scroll requested in \(pane.directory.lastPathComponent)")
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let id = pane.selection.first,
                      let row = pane.entries.firstIndex(where: { $0.id == id }) else {
                    DebugLog.open("scroll \(delay)s: nothing selected that is listed "
                        + "(selection \(pane.selection.first ?? "empty"), \(pane.entries.count) entries)")
                    return
                }
                scrollRowToVisible(row)
            }
        }
    }

    private func scrollRowToVisible(_ row: Int) {
        // the anchor sits behind this pane's table, so the first ancestor
        // with a table view in its subtree is ours, not the other pane's
        var node = anchor.view
        if node == nil { DebugLog.open("scroll: no anchor view") }
        while let view = node {
            if let table = Self.tableView(in: view) {
                guard row >= 0, row < table.numberOfRows else {
                    DebugLog.open("scroll: row \(row) but the table has \(table.numberOfRows) rows")
                    return
                }
                table.scrollRowToVisible(row)
                let visible = table.rows(in: table.visibleRect)
                DebugLog.open("row \(row) of \(table.numberOfRows): visible rows "
                    + "\(visible.location)…\(visible.location + visible.length - 1)")
                return
            }
            node = view.superview
        }
    }

    private static func tableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let found = tableView(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Context menu

    @ViewBuilder
    func contextMenuItems(for ids: Set<String>) -> some View {
        let entries = pane.entries.filter { ids.contains($0.id) }
        if entries.isEmpty {
            Button("New Folder") { activateThenRun { app.newFolderInActivePane() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Markdown File") { activateThenRun { app.newMarkdownInActivePane() } }
                .keyboardShortcut("n")
            Button("Open Second Pane Here") { tab.openInSecondPane(pane.directory) }
                .keyboardShortcut("2")
            Button(tab.viewerVisible ? "Close Viewer" : "Show Viewer") { tab.toggleViewer() }
                .keyboardShortcut("3")
            Button(pane.showsTiles ? "Show as List" : "Show as Tiles") { activateThenRun { app.toggleTiles() } }
                .keyboardShortcut("4")
            if pane.showsTiles {
                Button("Bigger Tiles") { Preferences.stepTileSize(bigger: true) }
                    .keyboardShortcut("+", modifiers: [.command, .option])
                Button("Smaller Tiles") { Preferences.stepTileSize(bigger: false) }
                    .keyboardShortcut("-", modifiers: [.command, .option])
            }
            Button("cd Terminal Here") { activateThenRun { app.cdTerminal() } }
                .keyboardShortcut("j")
            Button(app.clipboardIsCut ? "Paste — moves here" : "Paste") {
                activateThenRun { app.smartPaste() }
            }
            .keyboardShortcut("v")
            Divider()
            Button("Add Folder to Favourites") { app.addFavourite(pane.directory) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            // empty space: the folder itself, explicitly — the pane's
            // selection is untouched by the right-click and would win otherwise
            Button("Copy Folder Path") { activateThenRun { app.copyFolderPath() } }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            Button("Reveal in Finder") { activateThenRun { app.revealFolderInFinder() } }
        } else {
            let single = entries.count == 1 ? entries[0] : nil
            Button("Open") { activateThenRun(on: ids) { app.openSelectedItems() } }
                .keyboardShortcut("o")
            if let single, single.isNavigable {
                Button("Open in Second Pane") { tab.openInSecondPane(single.url) }
                    .keyboardShortcut("2")
                Button("Open in New Tab") { app.newTab(at: single.url) }
                    .keyboardShortcut(.return)
                Button("cd Terminal Here") { tab.sendTerminalCD(to: single.url) }
                    .keyboardShortcut("j")
            }
            let apps = AppState.applications(opening: entries.map(\.url))
            if !apps.isEmpty {
                Menu("Open With") {
                    ForEach(apps, id: \.self) { application in
                        Button(AppState.appName(application)) {
                            activateThenRun(on: ids) { app.open(entries.map(\.url), with: application) }
                        }
                    }
                }
            }
            Button("Quick Look") { activateThenRun(on: ids) { toggleQuickLook() } }
                .keyboardShortcut("y")
            Button(tab.viewerVisible ? "Close Viewer" : "Show in Viewer") {
                activateThenRun(on: ids) { tab.toggleViewer() }
            }
            .keyboardShortcut("3")
            Button(pane.showsTiles ? "Show as List" : "Show as Tiles") { activateThenRun(on: ids) { app.toggleTiles() } }
                .keyboardShortcut("4")
            Button("New Markdown File") { activateThenRun(on: ids) { app.newMarkdownInActivePane() } }
                .keyboardShortcut("n")
            Divider()
            Button("Copy") { activateThenRun(on: ids) { app.smartCopy() } }
                .keyboardShortcut("c")
            Button("Cut — paste moves") { activateThenRun(on: ids) { app.smartCut() } }
                .keyboardShortcut("x")
            Button("Rename") { activateThenRun(on: ids) { app.renameSelected() } }
                .keyboardShortcut("r")
            if tab.isDual {
                Button("Copy to Other Pane") { activateThenRun(on: ids) { app.copyToOtherPane(move: false) } }
                Button("Move to Other Pane") { activateThenRun(on: ids) { app.copyToOtherPane(move: true) } }
                    .keyboardShortcut("m")
            }
            Button("Move to Trash") { activateThenRun(on: ids) { app.moveToTrash() } }
                .keyboardShortcut(.delete)
            Divider()
            Button("Add to Favourites") { activateThenRun(on: ids) { app.addSelectionToFavourites() } }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Copy Path") { activateThenRun(on: ids) { app.copyPath() } }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Copy Folder Path") { activateThenRun { app.copyFolderPath() } }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            Button("Reveal in Finder") { activateThenRun(on: ids) { app.revealInFinder() } }
        }
    }

    /// Make this the pane that ⌘J & friends aim at, and give it the keyboard —
    /// unless another unit is driving it: the sidebar navigating a favourite,
    /// the terminal following a `cd`, or the rename sheet holding the field.
    func activateFromClick() {
        guard app.renameTarget == nil, !app.tabBarActive,
              focus.wrappedValue != .sidebar,
              app.activeTab?.terminalHasFocus != true else { return }
        tab.activePaneIndex = paneIndex
        if focus.wrappedValue != .pane(pane.id) {
            app.requestFocus(.pane(pane.id))
        }
    }

    /// Take the keyboard for this pane — but never out of another logical
    /// unit: the sidebar and the tab bar stay in charge while the user is
    /// arrowing through them (switching tabs rebuilds the panes below).
    private func claimFocus() {
        // nor out of a terminal that was just handed the keyboard — going to a
        // Claude session switches tabs and focuses its terminal, and this
        // pane's delayed claim used to take the keyboard straight back
        guard !app.tabBarActive, !tab.terminalHasFocus else { return }
        switch focus.wrappedValue {
        case .sidebar, .tabBar: return
        default: focus.wrappedValue = .pane(pane.id)
        }
    }

    /// Context menus can appear over the non-active pane; make this pane active
    /// first so AppState actions (which target the active pane) hit the right one.
    /// Every context-menu action runs through here. `rows` are the rows the
    /// menu was opened on. A right-click does not move the table's selection
    /// (measured: right-click b while a is selected — the menu is built for b,
    /// the selection stays a), and every action reads the SELECTION, so "Move
    /// to Trash" in b's menu trashed a. Selecting the clicked rows first makes
    /// the action hit what was clicked, as in Finder — and the viewer and
    /// Quick Look follow along.
    private func activateThenRun(on rows: Set<String> = [], _ action: @escaping () -> Void) {
        tab.activePaneIndex = paneIndex
        if !rows.isEmpty, rows != pane.selection { pane.selection = rows }
        action()
    }

    // MARK: - Actions

    private func open(ids: Set<String>) {
        tab.activePaneIndex = paneIndex
        pane.selection = ids
        openSelection()
    }

    func openSelection() {
        tab.activePaneIndex = paneIndex
        let sel = pane.selectedEntries
        if sel.count == 1, sel[0].isNavigable {
            pane.navigate(to: sel[0].url)
            return
        }
        for e in sel where !e.isNavigable {
            Opening.open(e.url)
        }
    }

    private func descendIntoSelection() -> KeyPress.Result {
        let sel = pane.selectedEntries
        guard sel.count == 1, sel[0].isNavigable else { return .ignored }
        pane.navigate(to: sel[0].url)
        return .handled
    }

    /// Space. The panel is driven through AppKit (see QuickLook) so that ↑ / ↓
    /// inside it walk the file list, as they do in Finder.
    func toggleQuickLook() {
        QuickLook.shared.toggle(for: pane) { delta in
            if pane.showsTiles { tileStep(by: delta) } else { step(by: delta) }
        }
    }

    /// One row up or down from the selection, as the table's own arrow keys
    /// would — for when the keys are going to the Quick Look panel instead.
    private func step(by delta: Int) {
        guard !pane.entries.isEmpty else { return }
        let current = pane.selection.first.flatMap { id in
            pane.entries.firstIndex { $0.id == id }
        } ?? (delta > 0 ? -1 : pane.entries.count)
        let next = min(max(current + delta, 0), pane.entries.count - 1)
        pane.selection = [pane.entries[next].id]
        scrollRowToVisible(next)
    }
}

/// A pane is the same pane while it shows the same PaneState in the same
/// place, with or without a terminal under it. The focus binding is left out on
/// purpose: SwiftUI sees it as new every time the window redraws, so without
/// this every focus move rebuilt both file lists. It always points at the same
/// FocusState, so the binding a pane already holds stays good. Changes to the
/// pane itself still redraw it — those come through @ObservedObject, not
/// through this comparison.
extension FilePaneView: Equatable {
    nonisolated static func == (a: FilePaneView, b: FilePaneView) -> Bool {
        a.tab === b.tab && a.pane === b.pane && a.paneIndex == b.paneIndex
            && a.terminalBelow == b.terminalBelow
    }
}

/// The pane's path bar — the one part of a pane that shows which pane is
/// active, so the one part that has to watch the tab.
private struct PaneHeader: View {
    @ObservedObject var tab: TabState
    @ObservedObject var pane: PaneState
    let paneIndex: Int
    /// FilePaneView's activateFromClick
    let activate: () -> Void

    @State private var hoveringPath = false
    @State private var pathCopied = false
    @AppStorage(Preferences.tileSizeKey) private var tileSize = Preferences.defaultTileSize
    @Environment(\.uiZoom) private var zoom

    private var isActivePane: Bool {
        !tab.isDual || tab.activePaneIndex == paneIndex
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .uiFont(11)
                .foregroundStyle(isActivePane ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            // The path is where you look for it, so it is where you take it
            // from: a click on it copies the full path. Only the path text —
            // a click anywhere else on the bar just makes the pane active, and
            // must not overwrite files you have on the clipboard.
            Text((pane.directory.path as NSString).abbreviatingWithTildeInPath)
                .uiFont(12, weight: isActivePane ? .semibold : .regular)
                .foregroundStyle(isActivePane ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .underline(hoveringPath)
                .lineLimit(1)
                .truncationMode(.head)
                .help("Click to copy \(pane.directory.path)")
                .onHover { hoveringPath = $0 }
                .onTapGesture {
                    activate()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pane.directory.path, forType: .string)
                    pathCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { pathCopied = false }
                }
            if pathCopied {
                Text("path copied")
                    .uiFont(10)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Spacer()
            if pane.selection.count > 1 {
                Text("\(pane.selection.count) selected")
                    .uiFont(10)
                    .foregroundStyle(.tertiary)
            }
            if pane.showHidden {
                Text("hidden shown")
                    .uiFont(10)
                    .foregroundStyle(.tertiary)
            }
            if pane.showsTiles {
                // tile size, for every pane showing tiles
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.3x3.fill")
                        .uiFont(8)
                        .foregroundStyle(.tertiary)
                    Slider(value: $tileSize, in: Preferences.tileSizes)
                        .controlSize(.mini)
                        .frame(width: 90 * zoom)
                        .accessibilityLabel("Tile size")
                    Image(systemName: "square.fill")
                        .uiFont(11)
                        .foregroundStyle(.tertiary)
                }
                .help("Tile size (⌥⌘+ / ⌥⌘−)")
            }
            if tab.isDual && paneIndex == 1 {
                Button {
                    tab.closeSecondPane()
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Second Pane (⌘1)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        // clicking a pane's header is the explicit "work in this pane" gesture
        .onTapGesture { activate() }
        .overlay(alignment: .bottom) {
            // unambiguous active-pane marker in dual-pane mode: this is the
            // pane that ⌘J, ⌘C/⌘M, and the terminal follow
            if tab.isDual && isActivePane {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
    }
}

/// Closure target for the programmatic Open With menu items.
private final class OpenWithAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// Holds the pane's anchor view. NSApp.keyWindow is nil whenever Marina is not
/// the active application, so a menu anchored through it silently fails to
/// appear; anchoring to a view that is actually in this pane cannot.
/// A folder row that accepts a drop, and shows that it will.
struct FolderDropTarget<Content: View>: View {
    @EnvironmentObject var app: AppState
    let folder: URL
    @ViewBuilder let content: () -> Content
    @State private var targeted = false

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(targeted ? 0.25 : 0))
            )
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                app.drop(files, into: folder)
                return true
            } isTargeted: { targeted = $0 }
    }
}

/// Sees every mouse-down inside the pane without taking any of them.
///
/// Clicking into the other pane used to make it active only indirectly: through
/// the selection changing — which a click on the row already selected does not
/// do, and which is ignored while the sidebar or a terminal still has the
/// keyboard — or through SwiftUI noticing the table took focus, which it does
/// not always. So the folder icon and the path sometimes stayed on the pane you
/// had left. A local event monitor sees the click itself.
private struct PaneClickWatcher: NSViewRepresentable {
    let onMouseDown: () -> Void

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onMouseDown = onMouseDown
        return view
    }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.onMouseDown = onMouseDown
    }

    final class WatcherView: NSView {
        var onMouseDown: (() -> Void)?
        private var monitor: Any?

        // never the target of a click itself: the table and the bar above it
        // still get every one
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window === self.window else { return }
                    let point = self.convert(event.locationInWindow, from: nil)
                    if self.bounds.contains(point) { self.onMouseDown?() }
                }
                return event
            }
        }
    }
}

final class PaneAnchorBox: ObservableObject {
    weak var view: NSView?
}

private struct PaneAnchor: NSViewRepresentable {
    let box: PaneAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}
