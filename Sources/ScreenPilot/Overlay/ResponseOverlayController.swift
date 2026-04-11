import AppKit
import SwiftUI

@MainActor
final class ResponseOverlayController {
    private var panel: OverlayPanel?
    private let model = ResponseModel()

    func show(initial: String) {
        model.text = initial
        model.isLoading = true

        let width: CGFloat = 520
        let height: CGFloat = 320
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.maxX - width - 24
        let y = visible.maxY - height - 24
        let rect = NSRect(x: x, y: y, width: width, height: height)

        let panel = OverlayPanel(contentRect: rect, acceptsInput: false)
        let view = ResponseView(model: model, onClose: { [weak self] in
            self?.close()
        })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: rect.size)
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(text: String, isError: Bool = false) {
        model.text = text
        model.isError = isError
        model.isLoading = false
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

@MainActor
final class ResponseModel: ObservableObject {
    @Published var text: String = ""
    @Published var isLoading: Bool = false
    @Published var isError: Bool = false
}
