import AppKit
import Combine

/// Why a dictation came to nothing, in words for the person holding Space —
/// a silent failure costs them a guess.
struct DictationError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Records one clip for as long as Space is held. The real one is the
/// microphone (MicrophoneRecorder); tests use a fake.
protocol ClipRecording: AnyObject {
    /// Open the microphone and record into `clip`. `started` comes back once
    /// it records, or with why it cannot — possibly after macOS has asked
    /// whether Marina may use the microphone.
    func start(into clip: URL, started: @escaping (DictationError?) -> Void)
    /// Stop and close the microphone; how long the clip is, in seconds.
    func stop() -> TimeInterval
}

/// Turns a clip into text. The real one is DictationWorker; tests use a fake.
protocol Transcribing: AnyObject {
    /// Whether the model is loaded and answering.
    var isReady: Bool { get }
    /// Start loading the model if it is not loaded: called the moment a hold
    /// is recognised, so a cold load overlaps the talking.
    func warmUp()
    func transcribe(_ clip: URL, prompt: String, done: @escaping (Result<String, DictationError>) -> Void)
}

/// Where dictated text goes: the terminal or text field that had the keyboard
/// when Space went down. It gets the text even if the keyboard has moved on
/// by the time Whisper answers — the words land where the cursor was.
protocol DictationTarget: AnyObject {
    /// A tap's space, held back until it was known to be one.
    func typeSpace()
    func insert(_ text: String)
    /// What sits just before the cursor; nil at the start of the line.
    var characterBeforeCursor: Character? { get }
    /// What the status shows beside.
    var view: NSView? { get }
}

/// Hold Space, talk, let go: the words appear at the cursor and are never
/// sent on their own — no Return is ever added. Everything but the key events
/// and the microphone is in here, and those come in through protocols, so the
/// whole of it can be driven with made-up events (Support/Dictation/tests).
final class DictationController: ObservableObject {
    enum Status: Equatable {
        case idle
        case listening
        /// `loading`: the model is not loaded yet, which takes a while
        case transcribing(loading: Bool)
        /// shown for a moment, then gone
        case message(String)
    }

    @Published private(set) var status = Status.idle

    /// A clip shorter than this is a brush of the key: dropped.
    static let shortest: TimeInterval = 0.4
    /// A hold that long has lost its release somewhere: it ends there.
    static let longest: TimeInterval = 120

    private var hold = HoldToTalk()
    private let makeRecorder: () -> ClipRecording
    private let transcriber: Transcribing
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private let prompt: () -> String
    private let clipFolder: URL

    /// The target of the press under way.
    private var target: DictationTarget?
    private enum Recording {
        case none
        case starting(URL, ClipRecording, released: Bool, cancelled: Bool)
        case recording(URL, ClipRecording)
    }
    private var recording = Recording.none
    /// Counts holds, so a timeout or a late microphone belongs to its own.
    private var holdNumber = 0
    private var messageNumber = 0

    init(recorder: @escaping () -> ClipRecording,
         transcriber: Transcribing,
         clipFolder: URL,
         after: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         prompt: @escaping () -> String) {
        makeRecorder = recorder
        self.transcriber = transcriber
        self.clipFolder = clipFolder
        self.after = after
        self.prompt = prompt
    }

    /// Where the press under way, or the last one, is dictating into.
    var targetView: NSView? { target?.view }

    /// Whether a press is under way — while it is, every key goes through
    /// `key(_:target:)`, wherever the keyboard is.
    var isActive: Bool { hold.state != .idle }

    /// One key event. `target` matters only for a Space going down with no
    /// press under way: nil there means "not a place for dictation". Returns
    /// whether the event should go on as usual.
    func key(_ event: HoldToTalk.Event, target newTarget: DictationTarget?) -> Bool {
        if event == .spaceDown(isRepeat: false), hold.state == .idle || hold.state == .cancelled {
            guard let newTarget else {
                // not a place for dictation: Space is Space there
                hold.abandon()
                return true
            }
            target = newTarget
        } else if hold.state == .idle {
            return true
        }
        let outcome = hold.handle(event)
        outcome.actions.forEach(perform)
        return outcome.passEvent
    }

    /// The keyboard went elsewhere mid-press.
    func interrupt() {
        if let action = hold.interrupt() { perform(action) }
    }

    private func perform(_ action: HoldToTalk.Action) {
        switch action {
        case .typeSpace:
            target?.typeSpace()
        case .startTimer(let generation):
            after(HoldToTalk.holdDelay) { [weak self] in
                _ = self?.key(.timerFired(generation: generation), target: nil)
            }
        case .startListening:
            startListening()
        case .stopListening:
            stopListening()
        case .cancelListening:
            cancelListening()
        }
    }

    // MARK: - Recording

    private func startListening() {
        holdNumber += 1
        let number = holdNumber
        status = .listening
        transcriber.warmUp()
        let clip = clipFolder.appendingPathComponent(UUID().uuidString + ".wav")
        let recorder = makeRecorder()
        recording = .starting(clip, recorder, released: false, cancelled: false)
        recorder.start(into: clip) { [weak self] error in
            self?.microphoneStarted(clip, recorder, error: error)
        }
        after(Self.longest) { [weak self] in
            guard let self, self.holdNumber == number, self.hold.state == .listening else { return }
            self.interrupt()
        }
    }

    private func microphoneStarted(_ clip: URL, _ recorder: ClipRecording, error: DictationError?) {
        guard case .starting(let url, _, let released, let cancelled) = recording, url == clip else {
            // a recording nobody wants any more
            _ = recorder.stop()
            discard(clip)
            return
        }
        if let error {
            recording = .none
            discard(clip)
            show(error.message)
            return
        }
        if cancelled {
            recording = .none
            _ = recorder.stop()
            discard(clip)
        } else if released {
            // let go while the microphone was still opening
            finish(clip, length: recorder.stop())
        } else {
            recording = .recording(clip, recorder)
        }
    }

    private func stopListening() {
        switch recording {
        case .starting(let clip, let recorder, _, let cancelled):
            recording = .starting(clip, recorder, released: true, cancelled: cancelled)
        case .recording(let clip, let recorder):
            finish(clip, length: recorder.stop())
        case .none:
            if status == .listening { status = .idle }
        }
    }

    private func cancelListening() {
        switch recording {
        case .starting(let clip, let recorder, let released, _):
            recording = .starting(clip, recorder, released: released, cancelled: true)
        case .recording(let clip, let recorder):
            recording = .none
            _ = recorder.stop()
            discard(clip)
        case .none:
            break
        }
        status = .idle
    }

    // MARK: - Text

    private func finish(_ clip: URL, length: TimeInterval) {
        recording = .none
        guard length >= Self.shortest else {
            discard(clip)
            if status == .listening { status = .idle }
            return
        }
        let target = self.target
        status = .transcribing(loading: !transcriber.isReady)
        transcriber.transcribe(clip, prompt: prompt()) { [weak self] result in
            guard let self else { return }
            // it is the person's voice: gone as soon as it has been read
            self.discard(clip)
            let busy = self.hold.state == .listening      // a new hold has begun
            switch result {
            case .success(let heard):
                let text = Self.clean(heard)
                if text.isEmpty {
                    if !busy { self.show("Heard nothing.") }
                } else if let target {
                    let space = target.characterBeforeCursor.map { !$0.isWhitespace } ?? false
                    target.insert(space ? " " + text : text)
                    if !busy { self.status = .idle }
                }
            case .failure(let error):
                if !busy { self.show(error.message) }
            }
        }
    }

    /// One line: never a Return, which would send what was dictated.
    static func clean(_ heard: String) -> String {
        heard.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func discard(_ clip: URL) {
        try? FileManager.default.removeItem(at: clip)
    }

    private func show(_ message: String) {
        messageNumber += 1
        let number = messageNumber
        status = .message(message)
        after(4) { [weak self] in
            guard let self, self.messageNumber == number, self.status == .message(message) else { return }
            self.status = .idle
        }
    }
}
