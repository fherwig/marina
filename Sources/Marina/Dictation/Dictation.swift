import AppKit
import SwiftUI
import Combine

/// Marina's end of dictation (Settings ▸ Voice ▸ Whisper): which key events reach the
/// controller, where the text goes, and the status shown beside it. The
/// logic itself is DictationController's.
@MainActor
enum Dictation {
    static let controller = DictationController(
        recorder: {
            // testing only: a file stands in for the microphone
            if let clip = Preferences.debugDictationClip { return FileClipRecorder(source: clip) }
            return MicrophoneRecorder()
        },
        transcriber: Transcription.shared,
        clipFolder: clipFolder,
        after: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
        prompt: { MainActor.assumeIsolated { knownNames() } })

    /// Private to this user (0700); each clip in it is deleted once read, and
    /// the folder when Marina quits.
    static let clipFolder: URL = {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("marina-dictation-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return folder
    }()

    private static var monitor: Any?
    private static var statusWatch: AnyCancellable?

    static func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            MainActor.assumeIsolated { pass(event) } ? event : nil
        }
        // Space may come up where Marina never sees it
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { controller.interrupt() }
            }
        }
        statusWatch = controller.$status.sink { status in
            // $status announces the change before it is made: show it after
            DispatchQueue.main.async {
                MainActor.assumeIsolated { DictationHUD.shared.show(status, beside: controller.targetView) }
            }
        }
    }

    static func shutDown() {
        DictationWorker.shared.stop()
        SpeechService.shared.disconnect()
        try? FileManager.default.removeItem(at: clipFolder)
    }

    /// Whether the event goes on as usual.
    private static func pass(_ event: NSEvent) -> Bool {
        guard Preferences.voiceInput == .whisper || controller.isActive else { return true }
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        let kind: HoldToTalk.Event
        switch (event.type, event.keyCode) {
        case (.keyDown, 49) where plain: kind = .spaceDown(isRepeat: event.isARepeat)
        case (.keyUp, 49): kind = .spaceUp
        case (.keyDown, 53): kind = .escape
        case (.keyDown, _): kind = .otherKey
        default: return true
        }
        let target = kind == .spaceDown(isRepeat: false) ? target(for: event) : nil
        return controller.key(kind, target: target)
    }

    /// A terminal or an editable text field with the keyboard — not in the
    /// middle of composing a character.
    private static func target(for event: NSEvent) -> DictationTarget? {
        // the event's window is the key window; the fallback is for an
        // instance driven in the background, which has none
        let window = event.window ?? NSApp.keyWindow
            ?? MarinaWindows.shared.current.flatMap { MarinaWindows.shared.window(for: $0) }
                .map { $0.attachedSheet ?? $0 }
        guard let responder = window?.firstResponder as? NSView else { return nil }
        if let terminal = responder as? MarinaTerminalView {
            guard !terminal.hasMarkedText(), let session = terminal.session else { return nil }
            return TerminalTarget(session: session)
        }
        if let text = responder as? NSTextView, text.isEditable, !text.hasMarkedText() {
            return TextViewTarget(textView: text)
        }
        return nil
    }

    /// Whisper's initial prompt: the word list from Settings first, then the
    /// folder names of the Claude sessions and favourites Marina knows,
    /// without repeats and under 600 characters. It does not learn; this is
    /// what makes "tmux ops" come out as "tmux-ops".
    static func knownNames() -> String {
        let listed = Preferences.dictationWords
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
        let known = ClaudeSessionsStore.shared.sessions.map(\.directory.lastPathComponent)
            + FavouritesStore.shared.items.map(\.lastPathComponent)
        var seen = Set<String>()
        var prompt = ""
        for word in (listed + known).map({ $0.trimmingCharacters(in: .whitespaces) }) where !word.isEmpty {
            guard seen.insert(word.lowercased()).inserted else { continue }
            let next = prompt.isEmpty ? word : prompt + ", " + word
            guard next.count <= 600 else { break }
            prompt = next
        }
        return prompt
    }
}

/// Dictation into a terminal: typed as though at the keyboard, which is also
/// what keeps an automatic cd off a half-dictated line.
final class TerminalTarget: DictationTarget {
    private weak var session: TerminalSession?
    init(session: TerminalSession) { self.session = session }
    func typeSpace() { session?.type(" ") }
    func insert(_ text: String) { session?.type(text) }
    var characterBeforeCursor: Character? { session?.characterBeforeCursor }
    var view: NSView? { session?.view }
}

/// Dictation into a text field (its field editor) or text view.
final class TextViewTarget: DictationTarget {
    private weak var textView: NSTextView?
    init(textView: NSTextView) { self.textView = textView }
    func typeSpace() { insert(" ") }
    func insert(_ text: String) {
        guard let textView else { return }
        textView.insertText(text, replacementRange: textView.selectedRange())
    }
    var characterBeforeCursor: Character? {
        guard let textView else { return nil }
        let text = textView.string as NSString
        let at = textView.selectedRange().location
        guard at > 0, at <= text.length else { return nil }
        return text.substring(with: NSRange(location: at - 1, length: 1)).first
    }
    var view: NSView? { textView }
}

// MARK: - Status

/// A small capsule beside the terminal or field being dictated into: what is
/// happening, and why when something went wrong. Never takes the keyboard or
/// the mouse.
@MainActor
final class DictationHUD {
    static let shared = DictationHUD()

    private let panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        return panel
    }()

    func show(_ status: DictationController.Status, beside view: NSView?) {
        guard status != .idle, let view, let window = view.window else { return hide() }
        let host = NSHostingView(rootView: DictationStatusView(status: status))
        let size = host.fittingSize
        panel.contentView = host
        let area = window.convertToScreen(view.convert(view.bounds, to: nil))
        // inside the bottom of a terminal, under a one-line field
        let y = area.height > 100 ? area.minY + 14 : area.minY - size.height - 6
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: y, width: size.width, height: size.height),
                       display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

struct DictationStatusView: View {
    let status: DictationController.Status

    var body: some View {
        HStack(spacing: 6) {
            switch status {
            case .listening:
                Image(systemName: "mic.fill").foregroundStyle(.red)
                Text("Listening. Let go of Space to insert, Esc to cancel.")
            case .transcribing(loading: true):
                ProgressView().controlSize(.small)
                Text("Loading Whisper \(Transcription.shared.loadingName): about 10 seconds the first time")
            case .transcribing(loading: false):
                ProgressView().controlSize(.small)
                Text("Turning speech into text")
            case .message(let text):
                Image(systemName: "exclamationmark.bubble")
                Text(text).lineLimit(3)
            case .idle:
                EmptyView()
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 420)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .padding(4)
    }
}
