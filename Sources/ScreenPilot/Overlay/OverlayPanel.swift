import AppKit

/// Frameless, dark, always-on-top panel that can appear above full-screen apps.
/// Shared base for input, response, and (future) highlight/annotation overlays.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect, acceptsInput: Bool) {
        var styleMask: NSWindow.StyleMask = [.nonactivatingPanel, .borderless, .fullSizeContentView]
        if acceptsInput {
            styleMask.insert(.titled) // required for some key-handling edge cases
        }
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        self.level = .screenSaver
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = false
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true
        self.appearance = NSAppearance(named: .darkAqua)
    }
}
