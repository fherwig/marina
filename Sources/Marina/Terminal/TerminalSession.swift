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
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }
}

final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
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
        // ⌘-combinations are menu equivalents and never reach the shell; ⌘V is
        // the exception, and pasteClipboard() marks that itself.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isFocused,
                  !event.modifierFlags.contains(.command) else { return event }
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

    private static func quote(_ url: URL) -> String {
        "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func focusTerminal() {
        view.window?.makeFirstResponder(view)
    }

    // MARK: - Copy & paste

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
        add("Copy", #selector(menuCopy(_:)), key: "c")
        add("Paste", #selector(menuPaste(_:)), key: "v")
        menu.addItem(.separator())
        add("Select All", #selector(menuSelectAll(_:)), key: "a")
        return menu
    }

    @objc private func menuCopy(_ sender: Any?) { copySelection() }
    @objc private func menuPaste(_ sender: Any?) { pasteClipboard() }
    @objc private func menuSelectAll(_ sender: Any?) { view.selectAll() }

    var isFocused: Bool {
        guard let window = view.window,
              let responder = window.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    func terminate() {
        send("\u{15}exit\n")
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
