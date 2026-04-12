import AppKit
import QuartzCore

/// Click-through side-car panel that draws a pulsing ring at a specific point
/// on a specific screen. Rendered above full-screen apps (`.screenSaver`
/// level) and passes every mouse event down to whatever is underneath, so the
/// user can keep working while the highlight is visible.
@MainActor
final class HighlightOverlayController {
    private var panel: OverlayPanel?

    /// Show a pulsing ring centered on `cgPoint`, given in the window server's
    /// global coordinate system (top-left origin, points — same space as
    /// `SCWindow.frame` / `ScreenshotCapture.CaptureResult.screenFrame`).
    func show(atCGPoint cgPoint: CGPoint) {
        guard let primary = NSScreen.screens.first else { return }
        let primaryHeight = primary.frame.height

        // CG global (top-left origin) → AppKit global (bottom-left origin).
        let appKitPoint = CGPoint(
            x: cgPoint.x,
            y: primaryHeight - cgPoint.y
        )

        // Find the NSScreen that actually contains the target point so the
        // panel is positioned on the right monitor; fall back to the main
        // screen if the point is somehow off-screen.
        let targetScreen = NSScreen.screens.first { $0.frame.contains(appKitPoint) }
            ?? NSScreen.main
            ?? primary

        let screenFrame = targetScreen.frame
        let localPoint = CGPoint(
            x: appKitPoint.x - screenFrame.origin.x,
            y: appKitPoint.y - screenFrame.origin.y
        )

        let panel = OverlayPanel(contentRect: screenFrame, acceptsInput: false)
        // Click-through: every event goes to the window underneath. This is
        // the whole point of the side-car — the user never interacts with it.
        panel.ignoresMouseEvents = true

        let view = HighlightView(frame: NSRect(origin: .zero, size: screenFrame.size),
                                 point: localPoint)
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Backing view for the highlight panel. Lays out a single pulsing CAShapeLayer
/// at a bottom-left-origin point (matching AppKit conventions, which is also
/// what a non-flipped NSView's backing layer uses for sublayer positioning).
private final class HighlightView: NSView {
    init(frame: NSRect, point: CGPoint) {
        super.init(frame: frame)
        wantsLayer = true
        let root = CALayer()
        root.frame = bounds
        layer = root

        let radius: CGFloat = 34
        let ring = CAShapeLayer()
        ring.path = CGPath(
            ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2),
            transform: nil
        )
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = NSColor.systemYellow.cgColor
        ring.lineWidth = 4
        ring.position = point
        ring.shadowColor = NSColor.systemYellow.cgColor
        ring.shadowRadius = 18
        ring.shadowOpacity = 0.9
        ring.shadowOffset = .zero
        root.addSublayer(ring)

        let inner = CAShapeLayer()
        inner.path = CGPath(
            ellipseIn: CGRect(x: -4, y: -4, width: 8, height: 8),
            transform: nil
        )
        inner.fillColor = NSColor.systemYellow.cgColor
        inner.strokeColor = NSColor.clear.cgColor
        inner.position = point
        root.addSublayer(inner)

        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.7
        pulse.toValue = 1.15
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ring.add(pulse, forKey: "pulse")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.45
        fade.toValue = 1.0
        fade.duration = 1.1
        fade.autoreverses = true
        fade.repeatCount = .infinity
        ring.add(fade, forKey: "fade")
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
