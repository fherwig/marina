import Foundation
import AppKit
import SwiftTerm

/// Owns one shell running inside a SwiftTerm view. The view is created once and
/// kept alive for the lifetime of the session, so folding the terminal away and
/// back does not restart the shell.
/// SwiftTerm's `mouseDown` only starts a selection — it never takes the
/// keyboard. Clicking into the terminal therefore left the file pane holding
/// focus, and ⌘C copied files instead of the selected text. A click is a click:
/// it gives this view the keyboard, like clicking a pane does.
final class MarinaTerminalView: LocalProcessTerminalView {
    /// The Mouse Reporting setting. `allowMouseReporting` itself is that
    /// setting, set aside while text is selected — see selectionChanged.
    var mouseReportingWanted = true {
        didSet { applyMouseReporting() }
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    /// While mouse reporting is allowed, SwiftTerm drops the selection on
    /// every byte of output (`feedPrepare`), whether or not the program has
    /// asked for the mouse. claude redraws all the time it works, so a
    /// selection lasted until its next frame and ⌘C found nothing to copy —
    /// measured with a probe: drag, one redraw, selection gone. So reporting
    /// is set aside while anything is selected, and output then leaves the
    /// selection alone, as it does with reporting off. A click elsewhere,
    /// typing or a resize ends the selection and hands the mouse back.
    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        applyMouseReporting()
    }

    private func applyMouseReporting() {
        allowMouseReporting = mouseReportingWanted && !selectionActive
    }
}

final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate, NSMenuDelegate {
    let view: MarinaTerminalView
    let startDirectory: URL

    var onCwdChange: ((URL) -> Void)?
    var onExit: (() -> Void)?
    private(set) var lastCwd: URL?
    /// Set by every keystroke, cleared by every prompt: true means there is
    /// half-typed input on the line that an automatic cd would trample.
    /// Watching keys rather than bytes on their way to the shell is deliberate
    /// — SwiftTerm answers the terminal queries zsh makes while starting up,
    /// and those replies are indistinguishable from typing at the byte level.
    private var typedSincePrompt = false
    private var keyMonitor: Any?

    init(startingAt directory: URL) {
        startDirectory = directory
        view = MarinaTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        super.init()
        view.processDelegate = self
        // SwiftTerm otherwise takes the system text colours, where "white" is
        // NSColor.textColor — about 85% white on a near-black grey. A real
        // terminal palette (plain white on black) reads much better, and it
        // stays readable if the Mac is in light appearance.
        view.nativeForegroundColor = .white
        view.nativeBackgroundColor = .black
        view.caretColor = .white
        view.font = Self.terminalFont()
        view.menu = contextMenu()
        view.mouseReportingWanted = Self.storedMouseReporting
        // ⌘-combinations are menu equivalents and never reach the shell; ⌘V is
        // the exception, and pasteClipboard() marks that itself.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // The event's own window, not just `isFocused`: a local monitor
            // sees every keystroke in the app, and a view goes on reporting
            // itself as its window's first responder while that window sits in
            // the background (measured). So with a second Marina window open,
            // typing anywhere marked *every* terminal as "half-typed input on
            // the line" — and only a fresh prompt in that particular terminal
            // ever cleared it, which is why the shell stopped following the
            // panes until you had run a command in it.
            guard let self, event.window === self.view.window, self.isFocused,
                  !event.modifierFlags.contains(.command) else { return event }
            if !self.typedSincePrompt {
                DebugLog.follow("key \(event.charactersIgnoringModifiers ?? "?") → typedSincePrompt")
            }
            self.typedSincePrompt = true
            return event
        }
        start()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    private func start() {
        let inherited = ProcessInfo.processInfo.environment
        // Minimal, Terminal.app-style environment. Deliberately NOT the app's
        // own environment: whoever launched Marina (Finder, or a Claude Code
        // session during development) must not leak session markers, conda
        // state, etc. into the shell. The login shell rebuilds PATH and the
        // rest from the usual profile files.
        var env: [String: String] = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            // Masquerade as Apple Terminal: the stock /etc/zshrc_Apple_Terminal
            // then emits OSC 7 on every prompt, which is how the file panes
            // follow the shell.
            "TERM_PROGRAM": "Apple_Terminal",
            "TERM_PROGRAM_VERSION": "455",
            "TERM_SESSION_ID": UUID().uuidString
        ]
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "SSH_AUTH_SOCK"] {
            if let value = inherited[key] { env[key] = value }
        }
        // guide mode: staged start-up files, so the pictures show no real prompt
        if let staged = GuideShots.shellStartupFolder { env["ZDOTDIR"] = staged }
        let envList = env.map { "\($0.key)=\($0.value)" }

        let shell = env["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        FileManager.default.changeCurrentDirectoryPath(startDirectory.path)
        view.startProcess(
            executable: shell,
            args: [],
            environment: envList,
            execName: "-\(shellName)"
        )
    }

    /// SF Mono at medium weight — thicker stems than the default regular, which
    /// is what actually carries contrast on black. Override without rebuilding:
    ///   defaults write org.fherwig.marina marina.terminalFont Menlo-Bold
    ///   defaults write org.fherwig.marina marina.terminalFontSize 13
    private static func terminalFont() -> NSFont {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: "marina.terminalFontSize")
        let size = stored > 0 ? CGFloat(stored) : 12.5
        if let name = defaults.string(forKey: "marina.terminalFont"),
           let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
    }

    /// Height of a classic 40-row terminal at the current font. Columns follow
    /// the pane width, so there is no matching default width.
    var defaultHeight: CGFloat {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: view.font)
        return ceil(lineHeight * 40) + 8
    }

    func send(_ text: String) {
        view.send(txt: text)
    }

    /// Ctrl-U first so a half-typed command does not swallow the cd.
    func cd(to url: URL) {
        send("\u{15}cd \(Self.quote(url))\n")
    }

    /// The automatic follow. No Ctrl-U: `canAcceptCD` has already established
    /// that the line is empty, and wiping a line the user is typing is exactly
    /// what an automatic action must never do.
    func followCD(to url: URL) {
        send("cd \(Self.quote(url))\n")
    }

    /// Why an automatic cd would, or would not, be sent right now.
    enum CDReadiness: String {
        case ready
        /// the shell is not up yet
        case noShell
        /// something else owns the terminal's foreground process group —
        /// claude, an editor, a build
        case busy
        /// there is input on the line that a cd would trample
        case typing
    }

    /// The shell must be sitting at its own prompt with nothing typed: the
    /// pty's foreground process group is the shell itself, and no key has been
    /// pressed since the last prompt. Anything else means hands off.
    var cdReadiness: CDReadiness {
        guard let process = view.process, process.childfd >= 0 else { return .noShell }
        let foreground = tcgetpgrp(process.childfd)
        guard foreground > 0, foreground == process.shellPid else { return .busy }
        return typedSincePrompt ? .typing : .ready
    }

    var canAcceptCD: Bool { cdReadiness == .ready }

    /// The three inputs behind `cdReadiness`, for the log — which of them is
    /// the one saying no has been guessed wrong before.
    var readinessDetail: String {
        let fd = view.process?.childfd ?? -1
        let shell = view.process?.shellPid ?? 0
        let foreground = fd >= 0 ? tcgetpgrp(fd) : -1
        return "fd=\(fd) shellPid=\(shell) fgpgrp=\(foreground) typed=\(typedSincePrompt) lastCwd=\(lastCwd?.path ?? "nil")"
    }

    private static func quote(_ url: URL) -> String {
        "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func focusTerminal() {
        view.window?.makeFirstResponder(view)
    }

    // MARK: - Copy & paste

    // MARK: - Mouse reporting

    private static let mouseReportingKey = "marina.mouseReporting"

    private static var storedMouseReporting: Bool {
        UserDefaults.standard.object(forKey: mouseReportingKey) as? Bool ?? true
    }

    /// While a program has asked for the mouse (`CSI ?1000h` and friends), a
    /// plain drag is sent to that program and selects nothing. (Whether claude
    /// asks is not settled: the sequences found in its executable earlier
    /// belong to the Bun runtime bundled with it.)
    ///
    /// Two ways out, and the first costs nothing: **shift-drag selects anyway**,
    /// xterm's convention, which SwiftTerm honours unless the program claims
    /// shift for itself with XTSHIFTESCAPE. This switch is the other way —
    /// hand the mouse back to the terminal for good, for when you would rather
    /// drag plainly and do not need the program's own mouse handling. It
    /// sticks, because having it snap back on the next terminal would be its
    /// own small mystery.
    var mouseReporting: Bool {
        get { view.mouseReportingWanted }
        set {
            objectWillChange.send()
            view.mouseReportingWanted = newValue
            UserDefaults.standard.set(newValue, forKey: Self.mouseReportingKey)
        }
    }

    var hasSelection: Bool { view.selectionActive }

    /// ⌘C in the terminal. Returns false when nothing is selected — the
    /// clipboard is then left alone rather than being wiped, which is what
    /// SwiftTerm's own `copy:` would do.
    @discardableResult
    func copySelection() -> Bool {
        guard let text = view.getSelection(), !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    /// ⌘V in the terminal — SwiftTerm's paste handles bracketed-paste mode.
    func pasteClipboard() {
        typedSincePrompt = true
        view.paste(view)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector, key: String) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            item.target = self
            menu.addItem(item)
        }
        menu.delegate = self
        add("Copy", #selector(menuCopy(_:)), key: "c")
        add("Paste", #selector(menuPaste(_:)), key: "v")
        menu.addItem(.separator())
        add("Select All", #selector(menuSelectAll(_:)), key: "a")
        menu.addItem(.separator())
        let mouse = NSMenuItem(title: "Mouse Reporting",
                               action: #selector(menuToggleMouseReporting(_:)),
                               keyEquivalent: "")
        mouse.target = self
        mouse.toolTip = "Off: a plain drag selects text. On: shift-drag selects, "
            + "and the program in the terminal gets the mouse."
        menu.addItem(mouse)
        mouseReportingItem = mouse
        let leftOnly = NSMenuItem(title: "Terminal Under Left Pane Only",
                                  action: #selector(menuToggleLeftOnly(_:)),
                                  keyEquivalent: "j")
        leftOnly.keyEquivalentModifierMask = [.command, .option]
        leftOnly.target = self
        menu.addItem(leftOnly)
        leftOnlyItem = leftOnly
        return menu
    }

    private weak var mouseReportingItem: NSMenuItem?
    private weak var leftOnlyItem: NSMenuItem?

    func menuWillOpen(_ menu: NSMenu) {
        mouseReportingItem?.state = mouseReporting ? .on : .off
        leftOnlyItem?.state = UserDefaults.standard.bool(forKey: "marina.terminalLeftOnly") ? .on : .off
    }

    /// The same switch as Terminal ▸ Terminal Under Left Pane Only (⌥⌘J);
    /// SessionView watches the default, so flipping it here moves the terminal.
    @objc private func menuToggleLeftOnly(_ sender: Any?) {
        let key = "marina.terminalLeftOnly"
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    @objc private func menuToggleMouseReporting(_ sender: Any?) {
        mouseReporting.toggle()
    }

    @objc private func menuCopy(_ sender: Any?) { copySelection() }
    @objc private func menuPaste(_ sender: Any?) { pasteClipboard() }
    @objc private func menuSelectAll(_ sender: Any?) { view.selectAll() }

    var isFocused: Bool {
        guard let window = view.window,
              let responder = window.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    /// The name of whatever holds the terminal's foreground, or nil when that
    /// is just the shell sitting at its prompt. Used to ask before closing.
    var runningProgram: String? {
        guard let process = view.process, process.childfd >= 0, process.shellPid > 0 else {
            return nil
        }
        let foreground = tcgetpgrp(process.childfd)
        guard foreground > 0, foreground != process.shellPid else { return nil }
        var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_name(foreground, &name, UInt32(MAXPATHLEN)) > 0 else { return "a program" }
        let text = String(cString: name)
        return text.isEmpty ? "a program" : text
    }

    /// Close the terminal for good.
    ///
    /// Typing `exit` — which this used to do — only works at an idle prompt:
    /// with claude or an editor in the foreground the word is typed into *that*
    /// program, the shell lives on parented to Marina, and nothing in the app
    /// can reach it again. Measured on 2026-09-27: three such shells had
    /// outlived their tabs, two of them running `claude -c` on the same folder
    /// and so very likely sharing one transcript.
    ///
    /// So do what a real terminal window does instead. SIGHUP the shell, which
    /// makes zsh hang up its own jobs, and the foreground job's process group
    /// directly as well — killing only the shell would leave its children
    /// reparented to launchd and every bit as invisible. Then close the pty.
    /// Anything still alive after a grace period is insisted upon: the point is
    /// that nothing outlives its tab unseen.
    func terminate() {
        guard let process = view.process, process.shellPid > 0 else { return }
        let shell = process.shellPid
        // read the foreground group before the pty goes; afterwards there is
        // nothing left to ask
        let foreground = process.childfd >= 0 ? tcgetpgrp(process.childfd) : -1

        kill(shell, SIGHUP)
        if foreground > 0, foreground != shell { kill(-foreground, SIGHUP) }
        process.terminate()          // closes the pty and sends SIGTERM

        let groups = [shell, foreground].filter { $0 > 0 }
        Self.insist(on: groups, after: 3, with: SIGTERM)
        Self.insist(on: groups, after: 6, with: SIGKILL)
    }

    private static func insist(on groups: [pid_t], after seconds: Double, with signal: Int32) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            for group in groups where kill(group, 0) == 0 {
                kill(-group, signal)
            }
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        var path: String?
        if let url = URL(string: directory), url.scheme == "file" {
            path = url.path
        } else if directory.hasPrefix("/") {
            path = directory
        }
        guard let path, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // the shell emits this from precmd, so it doubles as "a fresh
            // prompt is up and the input line is empty again"
            DebugLog.follow("osc7 \(url.path)  (typed was \(self.typedSincePrompt))")
            self.typedSincePrompt = false
            guard url.path != self.lastCwd?.path else { return }
            self.lastCwd = url
            self.onCwdChange?(url)
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            self?.onExit?()
        }
    }
}

extension TerminalSession: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(menuCopy(_:)) { return hasSelection }
        return true
    }
}
