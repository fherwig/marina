import Foundation
import Combine

/// The session dashboard's speech service: one Whisper model on this Mac for
/// every app that dictates, over a Unix socket (the kit's docs/SPEECH.md,
/// protocol 1). Marina uses it while it runs, and then loads no model of its
/// own; when there is none, or it goes away, Marina's own worker does the
/// work as before. Most people who install Marina will never have one.
///
/// Main thread only: the socket's reads are handed back to it.
final class SpeechService: ObservableObject {
    static let shared = SpeechService()

    enum Phase: Equatable {
        /// no service now, as far as Marina knows
        case absent
        /// connected, the greeting not yet read
        case connecting
        case loading
        case downloading
        case ready
    }

    @Published private(set) var phase = Phase.absent
    /// What the service holds, from its greeting: "whisper-small-mlx", "mlx".
    @Published private(set) var model: String?
    @Published private(set) var engine: String?

    /// How a clip sent here came out. Anything but text goes to Marina's own
    /// worker instead.
    enum Outcome {
        case text(String)
        case failed(String)
        case unavailable
    }

    /// How long a clip may wait for a model the service is still reading,
    /// before Marina's own worker takes it. A download is not waited for.
    static let loadingWait: TimeInterval = 15
    /// How long an answer may take, as the dashboard allows.
    static let answerWait: TimeInterval = 120

    private var handle: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var clips: [Int: (Outcome) -> Void] = [:]
    private var statusRequests: [Int: ([String: Any]?) -> Void] = [:]
    private var readyWaiters: [(Bool) -> Void] = []

    /// Where the dashboard says its service listens.
    static var configFile: URL {
        if let path = Preferences.debugSpeechConfig { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/session-dashboard/speech.json")
    }

    /// Connect if not connected. False when there is no service now: no
    /// file, no socket, or nobody listening on it (the file can outlive the
    /// service).
    @discardableResult
    func connect() -> Bool {
        if handle != nil { return true }
        guard let data = try? Data(contentsOf: Self.configFile),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = config["socket"] as? String,
              (config["protocol"] as? Int).map({ $0 == 1 }) ?? true else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); return false }
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(fd); return false }
        // a service that dies mid-write must not take Marina with it
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.received(data) }
        }
        self.handle = handle
        buffer = Data()
        phase = .connecting
        // the dashboard's 🎙 chip then shows that Marina shares the model
        send(["client": "marina"])
        return true
    }

    /// Send a clip. `done` comes back once, on the main thread.
    func transcribe(_ clip: URL, prompt: String, done: @escaping (Outcome) -> Void) {
        guard connect() else { return done(.unavailable) }
        switch phase {
        case .ready:
            sendClip(clip, prompt: prompt, done: done)
        case .connecting, .loading:
            whenReady(within: Self.loadingWait) { [weak self] ready in
                guard let self, ready else { return done(.unavailable) }
                self.sendClip(clip, prompt: prompt, done: done)
            }
        case .downloading, .absent:
            done(.unavailable)
        }
    }

    /// Settings ▸ Voice ▸ Check: what the service says of itself, or nil.
    func status(done: @escaping ([String: Any]?) -> Void) {
        guard connect() else { return done(nil) }
        let id = take()
        statusRequests[id] = done
        send(["id": id, "status": true])
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.statusRequests.removeValue(forKey: id)?(nil)
        }
    }

    func disconnect() {
        lost()
    }

    // MARK: -

    private func take() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func sendClip(_ clip: URL, prompt: String, done: @escaping (Outcome) -> Void) {
        let id = take()
        clips[id] = done
        send(["id": id, "path": clip.path, "prompt": prompt, "language": ""])
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.answerWait) { [weak self] in
            // too long: Marina's worker takes it, and a late answer is dropped
            self?.clips.removeValue(forKey: id)?(.unavailable)
        }
    }

    private func whenReady(within seconds: TimeInterval, _ go: @escaping (Bool) -> Void) {
        var answered = false
        let once: (Bool) -> Void = { ready in
            guard !answered else { return }
            answered = true
            go(ready)
        }
        readyWaiters.append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { once(false) }
    }

    private func send(_ object: [String: Any]) {
        guard let handle, var line = try? JSONSerialization.data(withJSONObject: object) else { return }
        line.append(0x0A)
        do {
            try handle.write(contentsOf: line)
        } catch {
            lost()
        }
    }

    private func received(_ data: Data) {
        guard handle != nil else { return }
        guard !data.isEmpty else { return lost() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            heard(object)
        }
    }

    private func heard(_ object: [String: Any]) {
        // a protocol Marina does not speak: as good as no service
        if let version = object["protocol"] as? Int, version != 1 { return lost() }
        if let id = object["id"] as? Int {
            if let done = clips.removeValue(forKey: id) {
                if let text = object["text"] as? String {
                    done(.text(text))
                } else {
                    done(.failed(object["error"] as? String ?? "no answer"))
                }
            } else if let done = statusRequests.removeValue(forKey: id) {
                done(object)
            }
            return
        }
        // where the service stands: its greeting, and every change after
        if let model = object["model"] as? String { self.model = (model as NSString).lastPathComponent }
        if let engine = object["engine"] as? String { self.engine = engine }
        if object["fatal"] as? Bool == true {
            // it exits after this
            lost()
        } else if object["ready"] as? Bool == true {
            phase = .ready
            let waiting = readyWaiters
            readyWaiters.removeAll()
            waiting.forEach { $0(true) }
        } else if object["downloading"] as? Bool == true {
            phase = .downloading
            failWaiters()
        } else if object["loading"] as? Bool == true {
            phase = .loading
        }
    }

    private func failWaiters() {
        let waiting = readyWaiters
        readyWaiters.removeAll()
        waiting.forEach { $0(false) }
    }

    /// The connection is gone: whatever waited on it goes to Marina's worker.
    private func lost() {
        handle?.readabilityHandler = nil
        try? handle?.close()
        handle = nil
        phase = .absent
        failWaiters()
        let waiting = clips.values
        clips.removeAll()
        waiting.forEach { $0(.unavailable) }
        let asking = statusRequests.values
        statusRequests.removeAll()
        asking.forEach { $0(nil) }
    }
}

/// What Marina transcribes with: the shared speech service while one
/// answers, Marina's own worker otherwise. The controller sees one
/// transcriber either way.
final class Transcription: Transcribing {
    static let shared = Transcription()

    private let service = SpeechService.shared
    private let worker = DictationWorker.shared

    var isReady: Bool { service.phase == .ready || worker.isReady }

    /// What "Loading Whisper …" names in the status: the service's model
    /// while Marina waits for it, else Marina's own.
    var loadingName: String {
        if service.phase == .loading, let model = service.model { return model }
        return Preferences.dictationModel
    }

    func warmUp() {
        // with a service there, Marina's own model stays unloaded: that is
        // the memory saved
        if !service.connect() { worker.warmUp() }
    }

    func transcribe(_ clip: URL, prompt: String, done: @escaping (Result<String, DictationError>) -> Void) {
        service.transcribe(clip, prompt: prompt) { [worker] outcome in
            if case .text(let text) = outcome {
                // a model of Marina's own left from a fallback is not needed now
                if worker.holdsIdleModel { worker.stop() }
                done(.success(text))
            } else {
                worker.transcribe(clip, prompt: prompt, done: done)
            }
        }
    }

    /// Settings ▸ Voice ▸ Check: the service when one answers, else
    /// Marina's own Whisper, loaded the way dictation would.
    func check(_ done: @escaping (Result<String, DictationError>) -> Void) {
        service.status { [worker] status in
            guard let status else { return worker.check(done) }
            let model = ((status["model"] as? String).map { ($0 as NSString).lastPathComponent }) ?? "?"
            let engine = status["engine"] as? String ?? "?"
            let others = (status["clients"] as? [String] ?? []).filter { $0 != "marina" }
            let shared = others.isEmpty ? "" : ", shared with \(others.joined(separator: ", "))"
            if status["loaded"] as? Bool == true {
                done(.success("Ready: the shared speech service, \(model) (\(engine))\(shared)."))
            } else {
                done(.success("The shared speech service is loading \(model) (\(engine))\(shared)."))
            }
        }
    }
}
