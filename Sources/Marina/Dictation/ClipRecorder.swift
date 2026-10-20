import AVFoundation

/// The default input device, mono 16 kHz WAV — what Whisper works in anyway.
/// The microphone is closed after every clip, so the recording light goes
/// out between them.
final class MicrophoneRecorder: ClipRecording {
    private var recorder: AVAudioRecorder?

    func start(into clip: URL, started: @escaping (DictationError?) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            started(begin(clip))
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    started(granted ? self.begin(clip) : Self.refused)
                }
            }
        default:
            started(Self.refused)
        }
    }

    private static let refused = DictationError("""
        Marina may not use the microphone. System Settings ▸ Privacy & \
        Security ▸ Microphone can allow it.
        """)

    private func begin(_ clip: URL) -> DictationError? {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        do {
            let recorder = try AVAudioRecorder(url: clip, settings: settings)
            guard recorder.record() else { return DictationError("The microphone would not start recording.") }
            self.recorder = recorder
            return nil
        } catch {
            return DictationError("The microphone would not start: \(error.localizedDescription)")
        }
    }

    func stop() -> TimeInterval {
        guard let recorder else { return 0 }
        let length = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        return length
    }
}

/// Testing only (`defaults write … marina.debugDictationClip <audio file>`):
/// a held Space "records" a copy of that file instead of the microphone, so a
/// sentence spoken by `say` can stand in for a voice.
final class FileClipRecorder: ClipRecording {
    let source: URL
    private var length: TimeInterval = 0

    init(source: URL) { self.source = source }

    func start(into clip: URL, started: @escaping (DictationError?) -> Void) {
        do {
            try FileManager.default.copyItem(at: source, to: clip)
            length = (try? AVAudioPlayer(contentsOf: source).duration) ?? 1
            started(nil)
        } catch {
            started(DictationError("The test clip could not be read: \(error.localizedDescription)"))
        }
    }

    func stop() -> TimeInterval { length }
}
