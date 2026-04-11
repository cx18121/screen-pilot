import AppKit
import CoreGraphics

enum ScreenshotCapture {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case captureFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return """
                Screen Recording permission is not granted. Without it, macOS returns only the \
                desktop wallpaper and hides every other window.

                Quit ScreenPilot, open System Settings → Privacy & Security → Screen Recording, \
                remove ScreenPilot from the list (click −), then relaunch and grant permission \
                when prompted. You'll need to quit and relaunch once more after granting.
                """
            case .captureFailed:
                return "Screen capture failed."
            }
        }
    }

    /// Captures the entire screen as a CGImage using CGWindowListCreateImage.
    ///
    /// `CGWindowListCreateImage` is a silent failure mode: without Screen Recording
    /// permission it returns a non-nil image containing only the desktop wallpaper
    /// and menu bar (every other app's window is masked out). We preflight the
    /// permission explicitly so we can surface a useful error instead of sending
    /// a wallpaper screenshot to Claude.
    static func captureFullScreen() throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
        guard let image = CGWindowListCreateImage(
            .infinite,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            throw CaptureError.captureFailed
        }
        return image
    }

    /// Downscale (to `maxDimension` on the long edge) and JPEG-encode a CGImage.
    ///
    /// Anthropic caps image uploads at 5MB and recommends ~1568px on the long
    /// edge for best quality/performance. A Retina screenshot is often 2880×1800
    /// and encodes to 8–15MB as PNG — way over the cap. JPEG at ~1568px on the
    /// long edge lands well under 1MB while still being legible.
    static func jpegData(
        from cgImage: CGImage,
        maxDimension: CGFloat = 1568,
        quality: CGFloat = 0.8
    ) -> Data? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let longest = max(width, height)
        let scale = longest > maxDimension ? (maxDimension / longest) : 1.0
        let targetWidth = max(1, Int((width * scale).rounded()))
        let targetHeight = max(1, Int((height * scale).rounded()))

        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        )
        guard let resized = context.makeImage() else { return nil }

        let rep = NSBitmapImageRep(cgImage: resized)
        return rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: quality]
        )
    }
}
