import AppKit
import CoreGraphics

/// Orchestrates the core loop: hotkey → screenshot → input → API → response.
/// Keeps every side-car concern (voice, highlighting, automation) out of the
/// hotpath so they can be added later without rewriting this file.
@MainActor
final class AssistantCoordinator {
    private let api = ClaudeClient()
    private let locator = ElementLocationDetector()
    private var inputController: InputOverlayController?
    private var responseController: ResponseOverlayController?
    private var highlightController: HighlightOverlayController?

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

        Task { @MainActor in
            let capture: ScreenshotCapture.CaptureResult
            do {
                capture = try await ScreenshotCapture.captureFocusedWindow()
            } catch {
                showError(error.localizedDescription)
                return
            }
            presentInput(for: capture)
        }
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

        // Any prior highlight is stale the moment a new question starts.
        highlightController?.close()
        highlightController = nil

        let response = ResponseOverlayController()
        responseController = response
        response.show(initial: "Thinking…")

        // Fire the pointing detector in parallel with the chat stream. It runs
        // against the full-resolution capture (not the JPEG the chat sends),
        // because the detector does its own aspect-matched resize. Failures
        // are swallowed inside `detect` — we never want this side-car to
        // block or surface errors on top of the main answer.
        let locator = self.locator
        let screenFrame = capture.screenFrame
        let sourceImage = capture.image
        Task { [weak self] in
            guard let loc = await locator.detect(question: question, image: sourceImage) else {
                return
            }
            await MainActor.run {
                guard let self = self else { return }
                // If the user dismissed everything mid-request, don't pop a
                // highlight onto an empty screen.
                guard self.responseController != nil else { return }
                self.presentHighlight(for: loc, sourceFrame: screenFrame)
            }
        }

        // Pull the focused window's pruned AX tree before encoding the image,
        // so we can downscale the screenshot when AX gives us a solid semantic
        // layer to fall back on. Nil for AX-hostile apps (Electron, games).
        let axTree = capture.pid.flatMap { AXExtractor.extractTree(forPID: $0) }

        // When AX is carrying the structural load, 1024px is still legible
        // for any remaining visual judgement and saves ~400 image tokens.
        // Without AX, keep the 1280px default so OCR + pixels stay sharp.
        let imageMaxDim: CGFloat = axTree != nil ? 1024 : 1280
        guard let imageData = ScreenshotCapture.jpegData(from: capture.image, maxDimension: imageMaxDim) else {
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
            screenText: screenText,
            axTree: axTree
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
        highlightController?.close()
        highlightController = nil
    }

    /// Map a detector coordinate (in resized-image pixel space) onto the
    /// global screen and show a click-through ring there. `sourceFrame` is the
    /// region the capture covered, in CG global points — dividing by the
    /// declared dimensions gives us a scale-independent fraction of that
    /// region.
    private func presentHighlight(
        for location: ElementLocationDetector.DetectedLocation,
        sourceFrame: CGRect
    ) {
        guard location.declaredWidth > 0, location.declaredHeight > 0 else { return }
        let ratioX = location.point.x / CGFloat(location.declaredWidth)
        let ratioY = location.point.y / CGFloat(location.declaredHeight)
        let cgPoint = CGPoint(
            x: sourceFrame.origin.x + ratioX * sourceFrame.width,
            y: sourceFrame.origin.y + ratioY * sourceFrame.height
        )

        highlightController?.close()
        let highlight = HighlightOverlayController()
        highlight.show(atCGPoint: cgPoint)
        highlightController = highlight
    }
}
