import AppKit

// Hold-to-talk and the dictation controller, driven with made-up key events,
// a fake clock, a fake microphone, a fake Whisper and a fake text field.
// Run with Support/Dictation/tests/run.sh.

final class Clock {
    var now: TimeInterval = 0
    private var due: [(at: TimeInterval, work: () -> Void)] = []
    func after(_ delay: TimeInterval, _ work: @escaping () -> Void) { due.append((now + delay, work)) }
    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let next = due.enumerated().filter({ $0.element.at <= end }).min(by: { $0.element.at < $1.element.at }) {
            due.remove(at: next.offset)
            now = next.element.at
            next.element.work()
        }
        now = end
    }
}

final class FakeRecorder: ClipRecording {
    /// nil: the microphone opens at once; otherwise it waits for `open()`
    var deferStart = false
    var error: DictationError?
    var length: TimeInterval = 1
    private(set) var started = 0
    private(set) var stopped = 0
    private var pending: (() -> Void)?

    func start(into clip: URL, started: @escaping (DictationError?) -> Void) {
        self.started += 1
        let go = { [self] in
            if error == nil { FileManager.default.createFile(atPath: clip.path, contents: Data([1, 2, 3])) }
            started(error)
        }
        if deferStart { pending = go } else { go() }
    }
    func open() { pending?(); pending = nil }
    func stop() -> TimeInterval { stopped += 1; return length }
}

final class FakeWhisper: Transcribing {
    var isReady = false
    private(set) var warmUps = 0
    private(set) var requests: [(clip: URL, prompt: String, existed: Bool)] = []
    private var answers: [(Result<String, DictationError>) -> Void] = []
    func warmUp() { warmUps += 1 }
    func transcribe(_ clip: URL, prompt: String, done: @escaping (Result<String, DictationError>) -> Void) {
        requests.append((clip, prompt, FileManager.default.fileExists(atPath: clip.path)))
        answers.append(done)
    }
    func answer(_ result: Result<String, DictationError>) { answers.removeFirst()(result) }
}

final class FakeField: DictationTarget {
    var log: [String] = []
    var before: Character?
    func typeSpace() { log.append("space") }
    func insert(_ text: String) { log.append("insert[\(text)]") }
    var characterBeforeCursor: Character? { before }
    var view: NSView? { nil }
}

var failures = 0
var checks = 0
func check(_ condition: Bool, _ what: String, line: Int = #line) {
    checks += 1
    if !condition { failures += 1; print("FAIL line \(line): \(what)") }
}

struct Rig {
    let clock = Clock()
    let mic = FakeRecorder()
    let whisper = FakeWhisper()
    let field = FakeField()
    let folder: URL
    let dictation: DictationController

    init() {
        // inside the folder run.sh hands over and deletes afterwards
        let base = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1]) : FileManager.default.temporaryDirectory
        folder = base.appendingPathComponent("clips-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clock = self.clock, mic = self.mic
        dictation = DictationController(recorder: { mic }, transcriber: whisper, clipFolder: folder,
                                        after: { clock.after($0, $1) }, prompt: { "tmux-ops, Marina" })
    }
    /// What happened to the event: passed on or swallowed.
    @discardableResult
    func key(_ event: HoldToTalk.Event, target: Bool = true) -> String {
        dictation.key(event, target: target ? field : nil) ? "pass" : "swallow"
    }
    var clips: [String] { (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] }
}

func scenario(_ name: String, _ body: (Rig) -> Void) {
    let before = failures
    body(Rig())
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}

scenario("a tap types one space, on key up, and records nothing") { r in
    check(r.key(.spaceDown(isRepeat: false)) == "swallow", "the space is held back")
    r.clock.advance(0.1)
    check(r.field.log.isEmpty, "nothing typed while it might be a hold")
    check(r.key(.spaceUp) == "swallow", "key up swallowed")
    check(r.field.log == ["space"], "the space typed on key up: \(r.field.log)")
    r.clock.advance(1)
    check(r.mic.started == 0 && r.dictation.status == .idle, "no microphone, no status")
}

scenario("a hold records, repeats are swallowed, the text lands at the cursor") { r in
    r.key(.spaceDown(isRepeat: false))
    r.clock.advance(0.34)
    check(r.mic.started == 0, "not yet a hold at 0.34 s")
    r.clock.advance(0.02)
    check(r.mic.started == 1 && r.whisper.warmUps == 1, "a hold at 0.35 s: microphone open, model warming")
    check(r.dictation.status == .listening, "status listening")
    for _ in 0..<3 { check(r.key(.spaceDown(isRepeat: true)) == "swallow", "key repeat swallowed") }
    r.clock.advance(1.5)
    check(r.key(.spaceUp) == "swallow", "release swallowed")
    check(r.mic.stopped == 1, "microphone closed")
    check(r.whisper.requests.count == 1 && r.whisper.requests[0].existed, "the clip sent to Whisper")
    check(r.whisper.requests.first?.prompt == "tmux-ops, Marina", "with the names to expect")
    check(r.dictation.status == .transcribing(loading: true), "status: loading the model")
    r.whisper.answer(.success("  Hello\nworld  "))
    check(r.field.log == ["insert[Hello world]"], "one line, no Return, no space at a line start: \(r.field.log)")
    check(r.clips.isEmpty, "the clip deleted once read: \(r.clips)")
    check(r.dictation.status == .idle, "status idle")
}

scenario("a space goes before the text when the cursor follows a word") { r in
    r.field.before = "x"
    r.key(.spaceDown(isRepeat: false)); r.clock.advance(1); r.key(.spaceUp)
    r.whisper.answer(.success("again"))
    check(r.field.log == ["insert[ again]"], "\(r.field.log)")
    let s = Rig(); s.field.before = " "
    s.key(.spaceDown(isRepeat: false)); s.clock.advance(1); s.key(.spaceUp)
    s.whisper.answer(.success("again"))
    check(s.field.log == ["insert[again]"], "none after a space: \(s.field.log)")
}

scenario("Esc while listening throws the clip away") { r in
    r.key(.spaceDown(isRepeat: false)); r.clock.advance(0.8)
    check(r.key(.escape) == "swallow", "Esc swallowed")
    check(r.clips.isEmpty && r.mic.stopped == 1, "microphone closed, clip gone")
    check(r.key(.spaceDown(isRepeat: true)) == "swallow", "repeats still swallowed")
    check(r.key(.spaceUp) == "swallow", "the release too")
    check(r.whisper.requests.isEmpty && r.field.log.isEmpty, "nothing transcribed, nothing typed")
    check(r.key(.otherKey) == "pass", "then keys are keys again")
}

scenario("keys overlapping a quick space: the space, then the key") { r in
    r.key(.spaceDown(isRepeat: false)); r.clock.advance(0.1)
    check(r.key(.otherKey) == "pass", "the other key goes on")
    check(r.field.log == ["space"], "after the space was typed")
    check(r.key(.spaceUp) == "pass", "a later key up is ordinary")
    r.clock.advance(1)
    check(r.mic.started == 0, "the old timer starts nothing")
}

scenario("a timer from an earlier tap does not end a later press early") { r in
    r.key(.spaceDown(isRepeat: false)); r.clock.advance(0.1); r.key(.spaceUp)      // tap
    r.clock.advance(0.2); r.key(.spaceDown(isRepeat: false))                         // at 0.3
    r.clock.advance(0.1)                                                             // 0.4: first timer due at 0.35
    check(r.mic.started == 0, "not listening at 0.4 s")
    r.clock.advance(0.3)                                                             // 0.7: second due at 0.65
    check(r.mic.started == 1, "listening once the second press is a hold")
}

scenario("let go while the microphone is still opening") { r in
    r.mic.deferStart = true
    r.mic.length = 0.2
    r.key(.spaceDown(isRepeat: false)); r.clock.advance(0.4)
    check(r.key(.spaceUp) == "swallow", "release swallowed")
    r.mic.open()
    check(r.mic.stopped == 1 && r.clips.isEmpty, "closed as it opened, the brush of a clip dropped")
    check(r.whisper.requests.isEmpty && r.dictation.status == .idle, "nothing transcribed")

    let s = Rig(); s.mic.deferStart = true
    s.key(.spaceDown(isRepeat: false)); s.clock.advance(0.4); s.key(.spaceUp); s.mic.open()
    check(s.whisper.requests.count == 1, "a long enough clip is still transcribed")
}

scenario("a brush of the key is dropped") { r in
    r.mic.length = 0.1
    r.key(.spaceDown(isRepeat: false)); r.clock.advance(0.45); r.key(.spaceUp)
    check(r.whisper.requests.isEmpty && r.clips.isEmpty && r.field.log.isEmpty, "dropped, nothing typed")
}

scenario("failures say why") { r in
    r.mic.error = DictationError("Marina may not use the microphone.")
    r.key(.spaceDown(isRepeat: false)); r.clock.advance(0.5)
    check(r.dictation.status == .message("Marina may not use the microphone."), "the refusal shown")
    r.key(.spaceUp)
    check(r.field.log.isEmpty && r.whisper.requests.isEmpty, "nothing typed")
    r.clock.advance(5)
    check(r.dictation.status == .idle, "the message goes after a while")

    let s = Rig()
    s.key(.spaceDown(isRepeat: false)); s.clock.advance(1); s.key(.spaceUp)
    s.whisper.answer(.failure(DictationError("Whisper did not load: no module")))
    check(s.dictation.status == .message("Whisper did not load: no module"), "Whisper's failure shown")
    check(s.clips.isEmpty, "the clip deleted anyway")

    let t = Rig()
    t.key(.spaceDown(isRepeat: false)); t.clock.advance(1); t.key(.spaceUp)
    t.whisper.answer(.success("  "))
    check(t.dictation.status == .message("Heard nothing.") && t.field.log.isEmpty, "silence says so")
}

scenario("Space where dictation does not happen is just Space") { r in
    check(r.key(.spaceDown(isRepeat: false), target: false) == "pass", "passed")
    r.clock.advance(1)
    check(r.mic.started == 0 && r.key(.spaceUp) == "pass", "no recording, key up passed")
}

scenario("the keyboard leaving mid-hold: what was said is kept") { r in
    r.key(.spaceDown(isRepeat: false)); r.clock.advance(1)
    r.dictation.interrupt()
    check(r.whisper.requests.count == 1, "transcribed as if released")
    check(r.key(.spaceDown(isRepeat: true)) == "swallow", "the still-held key's repeats swallowed")
    check(r.key(.spaceDown(isRepeat: false), target: false) == "pass", "a new press elsewhere passes")
    check(r.key(.spaceDown(isRepeat: false)) == "swallow", "a new press in a field starts over")
}

scenario("a hold that never ends stops at two minutes") { r in
    r.key(.spaceDown(isRepeat: false)); r.clock.advance(0.35)
    r.clock.advance(DictationController.longest + 1)
    check(r.whisper.requests.count == 1, "transcribed")
}

scenario("a new hold while the last clip is still being read") { r in
    r.key(.spaceDown(isRepeat: false)); r.clock.advance(1); r.key(.spaceUp)
    r.key(.spaceDown(isRepeat: false)); r.clock.advance(0.5)
    check(r.dictation.status == .listening, "listening again")
    r.whisper.answer(.success("first"))
    check(r.field.log == ["insert[first]"] && r.dictation.status == .listening, "first text in, still listening")
}

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
