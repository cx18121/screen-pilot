import SwiftUI

struct InputView: View {
    let placeholder: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    let onClearHistory: () -> Void

    @State private var text: String = ""
    @State private var isRecording: Bool = false
    @State private var voiceError: String? = nil
    @FocusState private var focused: Bool

    // Owned here so its lifetime matches the overlay. When the overlay closes,
    // SwiftUI drops the view and the recognizer deinits, stopping the engine.
    @State private var recognizer = SpeechRecognizer()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isRecording ? "waveform" : "sparkles")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isRecording ? Color.red.opacity(0.9) : .white.opacity(0.7))
                .symbolEffect(.pulse, options: .repeating, isActive: isRecording)

            TextField(voiceError ?? placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit(submit)

            // Invisible button bound to ⌘K that clears the conversation.
            // Rendered zero-size so it doesn't shift the layout but still
            // participates in keyboard shortcut routing.
            Button(action: {
                text = ""
                onClearHistory()
            }) {
                Color.clear.frame(width: 0, height: 0)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: [.command])

            // ⌘M toggles voice capture. Click-target is the mic button below.
            Button(action: toggleRecording) {
                Color.clear.frame(width: 0, height: 0)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("m", modifiers: [.command])

            Button(action: toggleRecording) {
                Image(systemName: isRecording ? "stop.circle.fill" : "mic.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isRecording ? Color.red.opacity(0.9) : .white.opacity(0.5))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Stop recording (⌘M)" : "Voice input (⌘M)")

            if !text.isEmpty {
                Text("↵")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )
        )
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focused = true
            }
        }
        .onExitCommand(perform: onCancel)
    }

    private func submit() {
        if isRecording { stopRecording() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        voiceError = nil
        PermissionsManager.ensureSpeech { granted in
            guard granted else {
                voiceError = "Voice input needs Speech + Microphone permission"
                return
            }
            recognizer.start(
                onPartialResult: { transcript in
                    text = transcript
                },
                onError: { error in
                    voiceError = error.localizedDescription
                    isRecording = false
                }
            )
            isRecording = recognizer.isRecording
        }
    }

    private func stopRecording() {
        recognizer.stop()
        isRecording = false
    }
}
