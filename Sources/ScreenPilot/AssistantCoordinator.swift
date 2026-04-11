import AppKit
import CoreGraphics

/// Orchestrates the core loop: hotkey → screenshot → input → API → response.
/// Keeps every side-car concern (voice, highlighting, automation) out of the
/// hotpath so they can be added later without rewriting this file.
@MainActor
final class AssistantCoordinator {
    private let api = ClaudeClient()
    private var inputController: InputOverlayController?
    private var responseController: ResponseOverlayController?

    // Conversation memory across ⌘⇧Space presses. Stores text-only turns —
    // prior screenshots are dropped on purpose, because every new press sends
    // a fresh screenshot and keeping old ones would balloon the request.
    private var history: [ChatMessage] = []
    private var lastActivity: Date?

    // If the user hasn't used the app in this long, the next trigger starts a
    // fresh conversation. Keeps the model from anchoring on stale context
    // from something you asked an hour ago.
    private let idleResetInterval: TimeInterval = 600

    // Cap on stored turns (user + assistant each count as one). Beyond this
    // we drop the oldest. 20 gives ~10 Q&A pairs.
    private let historyCap = 20

    func trigger() {
        // If an overlay is already visible, dismiss it instead of stacking.
        if inputController != nil || responseController != nil {
            dismissAll()
            return
        }

        pruneIdleHistory()

        let capture: ScreenshotCapture.CaptureResult
        do {
            capture = try ScreenshotCapture.captureFocusedWindow()
        } catch {
            showError(error.localizedDescription)
            return
        }

        presentInput(for: capture)
    }

    private func presentInput(for capture: ScreenshotCapture.CaptureResult) {
        let placeholder = history.isEmpty
            ? "Ask about your screen…"
            : "Follow up… (⌘K to start over)"

        let controller = InputOverlayController(
            placeholder: placeholder,
            onSubmit: { [weak self] question in
                self?.handleSubmission(question: question, capture: capture)
            },
            onCancel: { [weak self] in
                self?.inputController?.close()
                self?.inputController = nil
            },
            onClearHistory: { [weak self] in
                self?.history.removeAll()
                self?.lastActivity = nil
            }
        )
        inputController = controller
        controller.show()
    }

    private func handleSubmission(question: String, capture: ScreenshotCapture.CaptureResult) {
        inputController?.close()
        inputController = nil

        let response = ResponseOverlayController()
        responseController = response
        response.show(initial: "Thinking…")

        guard let imageData = ScreenshotCapture.jpegData(from: capture.image) else {
            response.update(text: "Failed to encode screenshot.", isError: true)
            return
        }

        // OCR the full-resolution image (before JPEG re-encoding loses fidelity)
        // so the model gets exact strings to quote back. Nil if Vision yields
        // too little text to be worth the tokens.
        let screenText = TextExtractor.extractText(from: capture.image)

        let context = RequestContext(
            activeApp: capture.appName,
            activeWindowTitle: capture.windowTitle,
            screenText: screenText
        )

        let historySnapshot = history

        Task { [weak self] in
            guard let self = self else { return }
            var accumulated = ""
            do {
                let stream = self.api.askStream(
                    question: question,
                    imageData: imageData,
                    imageMediaType: "image/jpeg",
                    history: historySnapshot,
                    context: context
                )
                for try await delta in stream {
                    accumulated += delta
                    let snapshot = accumulated
                    await MainActor.run {
                        response.update(text: snapshot)
                    }
                }
                await MainActor.run {
                    self.appendToHistory(question: question, answer: accumulated)
                }
            } catch {
                await MainActor.run {
                    // If we got a partial response before the error, keep it
                    // visible and append the failure reason rather than wiping
                    // the panel.
                    if accumulated.isEmpty {
                        response.update(text: error.localizedDescription, isError: true)
                    } else {
                        let combined = accumulated + "\n\n---\n*Stream ended: \(error.localizedDescription)*"
                        response.update(text: combined, isError: false)
                    }
                }
            }
        }
    }

    private func appendToHistory(question: String, answer: String) {
        guard !answer.isEmpty else { return }
        history.append(ChatMessage(role: .user, content: [.text(question)]))
        history.append(ChatMessage(role: .assistant, content: [.text(answer)]))
        if history.count > historyCap {
            history.removeFirst(history.count - historyCap)
        }
        lastActivity = Date()
    }

    private func pruneIdleHistory() {
        guard let last = lastActivity else { return }
        if Date().timeIntervalSince(last) > idleResetInterval {
            history.removeAll()
            lastActivity = nil
        }
    }

    private func showError(_ message: String) {
        let response = ResponseOverlayController()
        responseController = response
        response.show(initial: message)
        response.update(text: message, isError: true)
    }

    private func dismissAll() {
        inputController?.close()
        inputController = nil
        responseController?.close()
        responseController = nil
    }
}
