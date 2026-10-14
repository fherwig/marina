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
    /// ⌘3 — the viewer in place of a second file pane. The two share the slot,
    /// so opening one closes the other: two file panes and a viewer would leave
    /// nothing wide enough to be useful.
    @Published private(set) var viewerVisible = false

    @Published var terminalMaximized = false
    @Published var followTerminal = true
    /// The other direction: the shell cds after the file panes. Only ever
    /// fires while the shell is idle at its prompt — see `TerminalSession.canAcceptCD`.
    @Published var followPanes = true
    private var followWork: [Slot: DispatchWorkItem] = [:]
    /// The tab's terminal: across the width under both panes, or — with
    /// Terminal per Pane — the left pane's own.
    @Published private(set) var terminal: TerminalSession?

    /// With two file panes, the right pane's own terminal, beside the left
    /// one's. Closing the second pane only hides it —
    /// whatever runs in it is not killed for a layout change — and it is back
    /// when a second pane is.
    @Published private(set) var secondTerminal: TerminalSession?
    @Published var secondTerminalVisible = false
    /// Terminals Go to Session attached to a tmux session: which session, and
    /// whether it opened the terminal for that or used a shell already there.
    private var tmuxAttached: [Slot: (session: String, openedForIt: Bool)] = [:]

    /// A shell just detached from tmux: its next prompt reports the folder it
    /// was in before, and that must not drag the pane away from the folder
    /// that was just clicked. Ignored once, within a couple of seconds.
    private var ignoreCwdReport: [Slot: Date] = [:]

    /// A fresh attach, in a terminal just opened or in an idle shell.
    func markTmuxAttached(_ slot: Slot, session: String, openedForIt: Bool) {
        tmuxAttached[slot] = (session, openedForIt)
    }

    /// The client moved to another session: the terminal is still the one it
    /// was, opened for tmux or not.
    func markTmuxSwitched(_ slot: Slot, to session: String) {
        tmuxAttached[slot] = (session, tmuxAttached[slot]?.openedForIt ?? false)
    }
    @Published var secondTerminalMaximized = false

    /// Which of the two terminals something is about.
    enum Slot { case main, second }

    /// Each file pane has its own terminal whenever there are two of them.
    /// With the viewer beside the pane, or a single pane, there is just the one.
    var terminalPerPane: Bool { isDual }

    /// The terminal the active pane's commands act on — ⌘`, ⌘↓, ⌘J.
    var activeSlot: Slot { terminalPerPane && activePaneIndex == 1 ? .second : .main }

    func session(_ slot: Slot) -> TerminalSession? {
        slot == .main ? terminal : secondTerminal
    }

    func isVisible(_ slot: Slot) -> Bool {
        slot == .main ? terminalVisible : secondTerminalVisible
    }

    private func setVisible(_ slot: Slot, _ visible: Bool) {
        if slot == .main { terminalVisible = visible } else { secondTerminalVisible = visible }
    }

    func isMaximized(_ slot: Slot) -> Bool {
        slot == .main ? terminalMaximized : secondTerminalMaximized
    }

    private func setMaximized(_ slot: Slot, _ maximized: Bool) {
        if slot == .main { terminalMaximized = maximized } else { secondTerminalMaximized = maximized }
    }

    /// The pane a terminal belongs to: with Terminal per Pane, its own; the
    /// one shared terminal goes with whichever pane is active.
    private func pane(of slot: Slot) -> PaneState {
        if slot == .second, isDual { return panes[1] }
        return terminalPerPane ? panes[0] : activePane
    }

    /// Whichever terminal has the keyboard, if one does.
    var focusedTerminal: TerminalSession? {
        for slot in [Slot.main, .second] where isVisible(slot) {
            if let session = session(slot), session.isFocused { return session }
        }
        return nil
    }

    var hasTerminal: Bool { terminal != nil || secondTerminal != nil }

    /// What is still running in either terminal — closing the tab asks first.
    var runningProgram: String? {
        terminal?.runningProgram ?? secondTerminal?.runningProgram
    }

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
            guard let self, let pane else { return }
            self.objectWillChange.send()
            if self.terminalPerPane {
                self.terminalFollow(to: url, slot: pane === self.panes[0] ? .main : .second)
            } else if pane === self.activePane {
                self.terminalFollow(to: url, slot: .main)
            }
        }
        panes.append(pane)
    }

    // MARK: - Panes

    func openInSecondPane(_ url: URL) {
        // back to equal halves: the split is part of what ⌘2 means, and a
        // second pane opening into a sliver of the window is no use
        paneSplit = nil
        viewerVisible = false
        if panes.count < 2 {
            addPane(directory: url)
            // a second pane back over the terminal it left behind: that
            // terminal is this pane's again, so it comes along
            if terminalPerPane, secondTerminal != nil { terminalFollow(to: url, slot: .second) }
        } else {
            panes[1].navigate(to: url)
        }
    }

    func toggleViewer() {
        if viewerVisible {
            viewerVisible = false
            app?.requestFocus(.pane(activePane.id))
            return
        }
        if panes.count > 1 { closeSecondPane() }
        paneSplit = nil                     // equal halves, as ⌘2 gives
        viewerVisible = true
        // the keyboard stays in the file list: the viewer follows the
        // selection, so arrowing is how you use it
        app?.requestFocus(.pane(activePane.id))
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

    func ensureTerminal(_ slot: Slot = .main) {
        guard session(slot) == nil else { return }
        let start = pane(of: slot).directory
        logFollow("terminal created at \(start.path)")
        let session = TerminalSession(startingAt: start)
        session.onCwdChange = { [weak self] url in
            Task { @MainActor in self?.terminalMoved(to: url, slot: slot) }
        }
        session.onExit = { [weak self] in
            Task { @MainActor [weak session] in
                guard let self else { return }
                // only if it is still this slot's terminal: a replacement may
                // already have taken its place
                guard self.session(slot) === session else { return }
                if slot == .main { self.terminal = nil } else { self.secondTerminal = nil }
                self.setVisible(slot, false)
                self.setMaximized(slot, false)
                self.app?.requestFocus(.pane(self.pane(of: slot).id))
            }
        }
        if slot == .main { terminal = session } else { secondTerminal = session }
    }

    /// ⌘` — show + focus; if already focused, hide.
    func toggleTerminal() {
        let slot = activeSlot
        if !isVisible(slot) {
            ensureTerminal(slot)
            setVisible(slot, true)
            focusTerminalSoon(slot)
        } else if let t = session(slot), t.isFocused {
            setVisible(slot, false)
            setMaximized(slot, false)
            app?.requestFocus(.pane(pane(of: slot).id))
        } else {
            focusTerminalSoon(slot)
        }
    }

    /// ⌥⌘` — terminal takes the whole tab; file panes fold away.
    func toggleTerminalMaximized() {
        let slot = activeSlot
        ensureTerminal(slot)
        if !isVisible(slot) {
            setVisible(slot, true)
            setMaximized(slot, true)
            focusTerminalSoon(slot)
        } else {
            setMaximized(slot, !isMaximized(slot))
            if isMaximized(slot) {
                focusTerminalSoon(slot)
            } else {
                app?.requestFocus(.pane(pane(of: slot).id))
            }
        }
    }

    /// ⌘↓ — move keyboard focus down into the terminal, opening it if needed.
    func enterTerminal() {
        let slot = activeSlot
        ensureTerminal(slot)
        setVisible(slot, true)
        focusTerminalSoon(slot)
    }

    /// ⌘↑ from a focused terminal — climb back up to the file pane above it.
    func leaveTerminal() {
        let slot: Slot = secondTerminal.map { $0 === focusedTerminal } == true ? .second : .main
        if isMaximized(slot) { setMaximized(slot, false) }
        let above = pane(of: slot)
        if let index = panes.firstIndex(where: { $0 === above }) { activePaneIndex = index }
        app?.requestFocus(.pane(above.id))
    }

    var terminalHasFocus: Bool { focusedTerminal != nil }

    /// ⌘J — make the shell follow the file manager.
    func sendTerminalCD(to url: URL? = nil) {
        let slot = activeSlot
        ensureTerminal(slot)
        setVisible(slot, true)
        session(slot)?.cd(to: url ?? activePane.directory)
    }

    /// Pane moved — bring the shell along, once the walking stops. Arrowing
    /// down the sidebar steps the pane through a dozen folders and only the
    /// one it settles on is worth a cd.
    private func terminalFollow(to url: URL, slot: Slot) {
        logFollow("pane → \(url.path)")
        guard followPanes else { return }
        followWork[slot]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let terminal = self.session(slot) else { return self.logFollow("no terminal open") }
            guard self.followPanes else { return self.logFollow("Terminal Follows Panes is off") }
            let readiness = terminal.cdReadiness
            guard readiness == .ready else {
                return self.logFollow("\(readiness.rawValue) [\(terminal.readinessDetail)] — \(url.path)")
            }
            guard url.path != terminal.lastCwd?.path else { return self.logFollow("already there") }
            self.logFollow("cd \(url.path)")
            terminal.followCD(to: url)
        }
        followWork[slot] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func logFollow(_ text: @autoclosure () -> String) { DebugLog.follow(text()) }

    private func terminalMoved(to url: URL, slot: Slot) {
        // the second terminal's pane may be gone (⌘1); it follows nothing then
        guard slot == .main || terminalPerPane else { return }
        if let since = ignoreCwdReport.removeValue(forKey: slot), Date().timeIntervalSince(since) < 2 {
            // the prompt after a detach; Terminal Follows Panes brings the
            // shell to the pane instead
            return logFollow("terminal → \(url.path) ignored: just detached from tmux")
        }
        let target = pane(of: slot)
        logFollow("terminal → \(url.path)  (followTerminal=\(followTerminal), pane at \(target.directory.path))")
        guard followTerminal else { return }
        guard url.path != target.directory.path else { return }
        target.navigate(to: url)
    }

    private func focusTerminalSoon(_ slot: Slot) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.session(slot)?.focusTerminal()
        }
    }

    /// Clicking a folder in the sidebar while the active pane's terminal shows
    /// a tmux session Go to Session put there: leave the session. The session
    /// lives on in tmux — only this client goes. A terminal opened just for it
    /// closes; a shell that was already there is detached and folds away,
    /// still running. Left alone once tmux is no longer in the foreground, so
    /// nothing else the user ran there is touched.
    func leaveTmuxSession() {
        let slot = activeSlot
        guard let attached = tmuxAttached.removeValue(forKey: slot),
              let session = session(slot), session.runningProgram == "tmux",
              let tty = session.ttyPath else { return }
        // and still on the session it was put on — not a tmux the user has
        // since started there themselves
        let showing = ClaudeSessionScan.runTmux(["display-message", "-p", "-c", tty, "#{session_name}"])
        guard showing.trimmingCharacters(in: .whitespacesAndNewlines) == attached.session else { return }
        if attached.openedForIt {
            session.terminate()
            if slot == .main { terminal = nil } else { secondTerminal = nil }
        } else {
            ignoreCwdReport[slot] = Date()
            ClaudeSessionScan.runTmux(["detach-client", "-t", tty])
        }
        setVisible(slot, false)
        setMaximized(slot, false)
    }

    func shutdown() {
        terminal?.terminate()
        terminal = nil
        secondTerminal?.terminate()
        secondTerminal = nil
    }
}
