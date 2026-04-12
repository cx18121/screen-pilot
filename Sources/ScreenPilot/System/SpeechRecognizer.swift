import AVFoundation
import Speech

/// Thin wrapper around SFSpeechRecognizer + AVAudioEngine for push-to-talk input.
/// Streams partial transcripts via `onPartialResult` so the caller can mirror
/// them into whatever UI the user is editing. On-device recognition is preferred
/// when the installed locale supports it, so audio never leaves the machine.
@MainActor
final class SpeechRecognizer {
    enum RecognizerError: LocalizedError {
        case unavailable
        case notAuthorized
        case audioEngineFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Speech recognition isn't available for this locale."
            case .notAuthorized:
                return "Speech recognition or microphone permission was denied."
            case .audioEngineFailed(let detail):
                return "Audio engine failed: \(detail)"
            }
        }
    }

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Last non-empty transcript seen; used so the caller can restore text on
    /// cancel, and so a tap-to-stop mid-word doesn't lose the final partial.
    private(set) var lastTranscript: String = ""
    private(set) var isRecording: Bool = false

    init() {
        self.recognizer = SFSpeechRecognizer()
    }

    var isAvailable: Bool {
        recognizer?.isAvailable == true
    }

    /// Begin capturing audio and streaming transcripts. Caller must handle
    /// permission prompts via `PermissionsManager` before invoking this.
    func start(
        onPartialResult: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        guard !isRecording else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            onError(RecognizerError.unavailable)
            return
        }

        lastTranscript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device keeps audio local; falls back silently if unsupported.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            cleanup()
            onError(RecognizerError.audioEngineFailed(error.localizedDescription))
            return
        }

        isRecording = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.lastTranscript = text
                    onPartialResult(text)
                }
            }
            if error != nil || result?.isFinal == true {
                Task { @MainActor in
                    self.stop()
                }
            }
        }
    }

    /// Stop capturing. Safe to call multiple times.
    func stop() {
        guard isRecording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        cleanup()
    }

    private func cleanup() {
        request = nil
        task = nil
        isRecording = false
    }
}
