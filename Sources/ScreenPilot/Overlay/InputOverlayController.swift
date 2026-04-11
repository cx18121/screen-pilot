import AppKit
import SwiftUI

/// Manages the input overlay panel lifecycle.
/// Input sources (keyboard now, voice later) live behind this controller so the
/// coordinator only cares about "show input, get text back."
@MainActor
final class InputOverlayController {
    private var panel: OverlayPanel?
    private let onSubmit: (String) -> Void
    private let onCancel: () -> Void

    init(onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    func show() {
        let width: CGFloat = 640
        let height: CGFloat = 72
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let x = screenFrame.midX - width / 2
        let y = screenFrame.midY - height / 2 + 140
        let rect = NSRect(x: x, y: y, width: width, height: height)

        let panel = OverlayPanel(contentRect: rect, acceptsInput: true)
        let view = InputView(
            onSubmit: { [weak self] text in
                self?.onSubmit(text)
            },
            onCancel: { [weak self] in
                self?.onCancel()
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: rect.size)
        panel.contentView = hosting

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
