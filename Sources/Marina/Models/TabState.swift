import Foundation
import AppKit
import Combine

@MainActor
final class TabState: ObservableObject, Identifiable {
    nonisolated let id = UUID()

    @Published private(set) var panes: [PaneState] = []
    @Published var activePaneIndex = 0
    @Published var terminalVisible = false
    /// Height of the terminal slice, set by dragging the file pane's bottom
    /// bar. nil until it is dragged, when the 40-row default applies.
    @Published var terminalHeight: CGFloat?
    /// What the split has to divide up, kept by SessionView so the grip can
    /// clamp as it drags rather than banking travel past the limit.
    var availableHeight: CGFloat = 0

    /// Where the divider between the two panes sits, as a fraction of the
    /// width. nil means equal halves, which is what ⌘2 gives you and what it
    /// goes back to. Dragging the divider sets it.
    @Published var paneSplit: CGFloat?

    static let minTerminalHeight: CGFloat = 140
    static let minFilesHeight: CGFloat = 160
    static let minPaneWidth: CGFloat = 260

    /// Width of the left pane for a divider dragged to `wanted`, keeping both
    /// panes above their minimum.
    func clampPaneWidth(_ wanted: CGFloat, total: CGFloat) -> CGFloat {
        let low = Self.minPaneWidth
        let high = max(low, total - Self.minPaneWidth)
        return min(max(wanted, low), high)
    }

    /// The left pane's width right now — half, unless a drag said otherwise.
    func paneWidth(total: CGFloat) -> CGFloat {
        clampPaneWidth((paneSplit ?? 0.5) * total, total: total)
    }

    /// The terminal height a drag to `wanted` should actually produce.
    func clampTerminalHeight(_ wanted: CGFloat) -> CGFloat {
        let room = max(Self.minTerminalHeight, availableHeight - Self.minFilesHeight)
        return min(max(wanted, Self.minTerminalHeight), room)
    }
    @Published var terminalMaximized = false
    @Published var followTerminal = true
    /// The other direction: the shell cds after the file panes. Only ever
    /// fires while the shell is idle at its prompt — see `TerminalSession.canAcceptCD`.
    @Published var followPanes = true
    private var followWork: DispatchWorkItem?
    @Published private(set) var terminal: TerminalSession?

    weak var app: AppState?

    init(directory: URL, app: AppState?) {
        self.app = app
        addPane(directory: directory)
    }

    var isDual: Bool { panes.count == 2 }

    var activePane: PaneState {
        panes[min(activePaneIndex, panes.count - 1)]
    }

    var otherPane: PaneState? {
        guard isDual else { return nil }
        return panes[1 - min(activePaneIndex, 1)]
    }

    var title: String {
        let name = activePane.directory.lastPathComponent
        if activePane.directory.path == NSHomeDirectory() { return "Home" }
        return name.isEmpty ? "/" : name
    }

    private func addPane(directory: URL) {
        let pane = PaneState(directory: directory)
        pane.onDirectoryChange = { [weak self, weak pane] url in
            guard let self else { return }
            self.objectWillChange.send()
            UserDefaults.standard.set(url.path, forKey: "marina.lastDir")
            if let pane, pane === self.activePane { self.terminalFollow(to: url) }
        }
        panes.append(pane)
    }

    // MARK: - Panes

    func openInSecondPane(_ url: URL) {
        // back to equal halves: the split is part of what ⌘2 means, and a
        // second pane opening into a sliver of the window is no use
        paneSplit = nil
        if panes.count < 2 {
            addPane(directory: url)
        } else {
            panes[1].navigate(to: url)
        }
    }

    func closeSecondPane() {
        guard panes.count == 2 else { return }
        if activePaneIndex == 1 { activePaneIndex = 0 }
        panes.removeLast()
        app?.requestFocus(.pane(panes[0].id))
    }

    func switchPane() {
        guard isDual else { return }
        activePaneIndex = 1 - activePaneIndex
        app?.requestFocus(.pane(activePane.id))
    }

    // MARK: - Terminal

    func ensureTerminal() {
        guard terminal == nil else { return }
        logFollow("terminal created at \(activePane.directory.path)")
        let session = TerminalSession(startingAt: activePane.directory)
        session.onCwdChange = { [weak self] url in
            Task { @MainActor in self?.terminalMoved(to: url) }
        }
        session.onExit = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.terminal = nil
                self.terminalVisible = false
                self.terminalMaximized = false
                self.app?.requestFocus(.pane(self.activePane.id))
            }
        }
        terminal = session
    }

    /// ⌘` — show + focus; if already focused, hide.
    func toggleTerminal() {
        if !terminalVisible {
            ensureTerminal()
            terminalVisible = true
            focusTerminalSoon()
        } else if let t = terminal, t.isFocused {
            terminalVisible = false
            terminalMaximized = false
            app?.requestFocus(.pane(activePane.id))
        } else {
            focusTerminalSoon()
        }
    }

    /// ⌥⌘` — terminal takes the whole tab; file panes fold away.
    func toggleTerminalMaximized() {
        ensureTerminal()
        if !terminalVisible {
            terminalVisible = true
            terminalMaximized = true
            focusTerminalSoon()
        } else {
            terminalMaximized.toggle()
            if terminalMaximized {
                focusTerminalSoon()
            } else {
                app?.requestFocus(.pane(activePane.id))
            }
        }
    }

    /// ⌘↓ — move keyboard focus down into the terminal, opening it if needed.
    func enterTerminal() {
        ensureTerminal()
        terminalVisible = true
        focusTerminalSoon()
    }

    /// ⌘↑ from a focused terminal — climb back up to the file pane.
    func leaveTerminal() {
        if terminalMaximized { terminalMaximized = false }
        app?.requestFocus(.pane(activePane.id))
    }

    var terminalHasFocus: Bool {
        terminalVisible && (terminal?.isFocused ?? false)
    }

    /// ⌘J — make the shell follow the file manager.
    func sendTerminalCD(to url: URL? = nil) {
        ensureTerminal()
        terminalVisible = true
        terminal?.cd(to: url ?? activePane.directory)
    }

    /// Pane moved — bring the shell along, once the walking stops. Arrowing
    /// down the sidebar steps the pane through a dozen folders and only the
    /// one it settles on is worth a cd.
    private func terminalFollow(to url: URL) {
        logFollow("pane → \(url.path)")
        guard followPanes else { return }
        followWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let terminal = self.terminal else { return self.logFollow("no terminal open") }
            guard self.followPanes else { return self.logFollow("Terminal Follows Panes is off") }
            let readiness = terminal.cdReadiness
            guard readiness == .ready else {
                return self.logFollow("\(readiness.rawValue) [\(terminal.readinessDetail)] — \(url.path)")
            }
            guard url.path != terminal.lastCwd?.path else { return self.logFollow("already there") }
            self.logFollow("cd \(url.path)")
            terminal.followCD(to: url)
        }
        followWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func logFollow(_ text: @autoclosure () -> String) { DebugLog.follow(text()) }

    private func terminalMoved(to url: URL) {
        logFollow("terminal → \(url.path)  (followTerminal=\(followTerminal), pane at \(activePane.directory.path))")
        guard followTerminal else { return }
        guard url.path != activePane.directory.path else { return }
        activePane.navigate(to: url)
    }

    private func focusTerminalSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.terminal?.focusTerminal()
        }
    }

    func shutdown() {
        terminal?.terminate()
        terminal = nil
    }
}
