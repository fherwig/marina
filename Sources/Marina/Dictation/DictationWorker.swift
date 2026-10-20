import Foundation

/// One Python process that keeps a Whisper model loaded and answers one JSON
/// line per clip — the protocol in Support/Dictation/dictate_worker.py. It is
/// stopped after the time set in Settings with nothing to do, since a loaded
/// model holds 1.5 GB of memory (small), and whenever the Python or the model
/// changes.
final class DictationWorker: Transcribing {
    static let shared = DictationWorker()

    private enum State { case stopped, loading, ready }
    private var state = State.stopped
    private var process: Process?
    private var input: FileHandle?
    private var pending: [(clip: URL, prompt: String, done: (Result<String, DictationError>) -> Void)] = []
    /// The request sent and not yet answered.
    private var inFlight: ((Result<String, DictationError>) -> Void)?
    private var readyWaiters: [(Result<String, DictationError>) -> Void] = []
    private var outBuffer = Data()
    /// The end of what the worker wrote to stderr, for when it fails.
    private var errTail = ""
    private var unloadWork: DispatchWorkItem?
    private var loadStarted = Date()

    var isReady: Bool { state == .ready }

    /// Loaded, or loading, with nothing to do: safe to stop.
    var holdsIdleModel: Bool {
        state != .stopped && inFlight == nil && pending.isEmpty && readyWaiters.isEmpty
    }

    func warmUp() {
        if state == .stopped { launch() }
        keepAlive()
    }

    func transcribe(_ clip: URL, prompt: String, done: @escaping (Result<String, DictationError>) -> Void) {
        pending.append((clip, prompt, done))
        if state == .stopped { launch() }
        sendNext()
    }

    /// Settings ▸ Voice ▸ Check: load the model and say how that went.
    func check(_ done: @escaping (Result<String, DictationError>) -> Void) {
        if state == .ready {
            done(.success("Ready: Whisper \(Preferences.dictationModel) is loaded."))
            return
        }
        readyWaiters.append(done)
        if state == .stopped { launch() }
        keepAlive()
    }

    /// Unload: the next dictation starts a fresh worker with the settings
    /// as they are then.
    func stop() {
        unloadWork?.cancel()
        guard let process else { return }
        // closing stdin ends the worker's loop; terminate in case it is
        // still loading
        try? input?.close()
        if process.isRunning { process.terminate() }
        finish(with: DictationError("Dictation was stopped."))
    }

    // MARK: -

    private func launch() {
        guard let script = Bundle.main.url(forResource: "dictate_worker", withExtension: "py") else {
            return fail(DictationError("Marina's dictation worker is missing from the app."))
        }
        let python = Preferences.dictationPython
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            return fail(DictationError("""
                No Python at \(python.path). Settings ▸ Voice names the Python \
                that has openai-whisper.
                """))
        }
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, Preferences.dictationModel]
        // an app's PATH is short; Whisper decodes with ffmpeg, which may sit
        // beside the Python (conda) or in Homebrew's folders
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "PATH": [python.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                     "/usr/bin", "/bin"].joined(separator: ":"),
            "PYTHONUNBUFFERED": "1",
        ]
        for key in ["HOME", "USER", "LANG", "TMPDIR"] {
            if let value = inherited[key] { env[key] = value }
        }
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.received(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.receivedError(data) }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            DispatchQueue.main.async {
                guard let self, let process, self.process === process else { return }
                self.exited(status: process.terminationStatus)
            }
        }
        do {
            try process.run()
        } catch {
            return fail(DictationError("Could not start \(python.path): \(error.localizedDescription)"))
        }
        self.process = process
        input = stdin.fileHandleForWriting
        state = .loading
        loadStarted = Date()
        outBuffer = Data()
        errTail = ""
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        outBuffer.append(data)
        while let newline = outBuffer.firstIndex(of: 0x0A) {
            let line = outBuffer[outBuffer.startIndex..<newline]
            outBuffer.removeSubrange(outBuffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func receivedError(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        errTail = String((errTail + text).suffix(2000))
    }

    private func handle(_ object: [String: Any]) {
        if state == .loading {
            if object["ready"] as? Bool == true {
                state = .ready
                let load = object["load"] as? Double ?? Date().timeIntervalSince(loadStarted)
                let message = "Ready: Whisper \(Preferences.dictationModel) loaded in \(String(format: "%.1f", load)) s."
                readyWaiters.forEach { $0(.success(message)) }
                readyWaiters.removeAll()
                sendNext()
                keepAlive()
            } else {
                // it exits after this; the termination handler cleans up
                let error = object["error"] as? String ?? "the model did not load"
                finish(with: DictationError(error.contains("No module named 'whisper'")
                    ? Self.noWhisper(in: Preferences.dictationPython)
                    : "Whisper did not load: \(error)"))
            }
            return
        }
        guard let done = inFlight else { return }
        inFlight = nil
        if let text = object["text"] as? String {
            done(.success(text))
        } else {
            done(.failure(DictationError("Whisper could not read the recording: \(object["error"] as? String ?? "no answer")")))
        }
        sendNext()
        keepAlive()
    }

    /// Where to go from a Python without Whisper: to one that has it, if
    /// Marina found one, or to installing it.
    static func noWhisper(in python: URL) -> String {
        let found = Preferences.defaultPython
        let named = (python.path as NSString).abbreviatingWithTildeInPath
        if found != python, Preferences.hasWhisper(found.path) {
            return """
                \(named) has no Whisper. \((found.path as NSString).abbreviatingWithTildeInPath) \
                has it: clear the Python field to use that one.
                """
        }
        return "\(named) has no Whisper. Install it there (pip install openai-whisper), or choose the Python that has it."
    }

    private func sendNext() {
        guard state == .ready, inFlight == nil, !pending.isEmpty, let input else { return }
        let next = pending.removeFirst()
        let request: [String: Any] = ["path": next.clip.path, "prompt": next.prompt, "language": ""]
        guard var line = try? JSONSerialization.data(withJSONObject: request) else { return }
        line.append(0x0A)
        inFlight = next.done
        do {
            try input.write(contentsOf: line)
        } catch {
            inFlight = nil
            next.done(.failure(DictationError("The dictation worker stopped listening.")))
        }
    }

    private func exited(status: Int32) {
        let detail = errTail.split(separator: "\n").last.map(String.init) ?? "exit status \(status)"
        finish(with: DictationError("The dictation worker stopped: \(detail)"))
    }

    /// Everything waiting gets this error, and the worker is gone.
    private func finish(with error: DictationError) {
        let process = self.process
        self.process = nil
        input = nil
        state = .stopped
        unloadWork?.cancel()
        if let process {
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        }
        let waiting = (inFlight.map { [$0] } ?? []) + pending.map(\.done) + readyWaiters
        inFlight = nil
        pending.removeAll()
        readyWaiters.removeAll()
        waiting.forEach { $0(.failure(error)) }
    }

    private func fail(_ error: DictationError) {
        finish(with: error)
    }

    /// Restart the countdown to unloading.
    private func keepAlive() {
        unloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.inFlight == nil, self.pending.isEmpty else { return }
            self.stop()
        }
        unloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(Preferences.dictationUnloadMinutes) * 60,
                                      execute: work)
    }
}
