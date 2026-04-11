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

    // Reserved for future session memory. V1 stays empty per spec.
    private var history: [ChatMessage] = []

    func trigger() {
        // If an overlay is already visible, dismiss it instead of stacking.
        if inputController != nil || responseController != nil {
            dismissAll()
            return
        }

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
        let controller = InputOverlayController(
            onSubmit: { [weak self] question in
                self?.handleSubmission(question: question, capture: capture)
            },
            onCancel: { [weak self] in
                self?.inputController?.close()
                self?.inputController = nil
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

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let answer = try await self.api.ask(
                    question: question,
                    imageData: imageData,
                    imageMediaType: "image/jpeg",
                    history: self.history,
                    context: context
                )
                await MainActor.run {
                    response.update(text: answer)
                }
            } catch {
                await MainActor.run {
                    response.update(text: error.localizedDescription, isError: true)
                }
            }
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
