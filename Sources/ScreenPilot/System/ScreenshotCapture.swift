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

    /// Result of a capture, bundling the image with window metadata that the
    /// coordinator forwards to the model as context.
    struct CaptureResult {
        let image: CGImage
        let appName: String?
        let windowTitle: String?
    }

    /// Captures the frontmost window of the active application, with metadata.
    /// Falls back to full-screen capture if no suitable window is found (e.g.
    /// Finder desktop, fullscreen game). Menu bar, dock, and other apps'
    /// windows are excluded — the model sees only what the user is focused on.
    static func captureFocusedWindow() throws -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return CaptureResult(image: try captureFullScreen(), appName: nil, windowTitle: nil)
        }
        let frontPID = frontApp.processIdentifier
        let appName = frontApp.localizedName

        let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        // CGWindowListCopyWindowInfo returns windows in front-to-back z-order.
        // We want the topmost normal-layer window owned by the frontmost app
        // that is big enough to be a real content window (not a tooltip/menu).
        let target = infoList.first { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == frontPID else {
                return false
            }
            if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 {
                return false
            }
            if let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
               let w = bounds["Width"], let h = bounds["Height"],
               w < 200 || h < 200 {
                return false
            }
            return true
        }

        guard let info = target,
              let windowID = info[kCGWindowNumber as String] as? CGWindowID,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else {
            return CaptureResult(image: try captureFullScreen(), appName: appName, windowTitle: nil)
        }

        let rect = CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )

        guard let image = CGWindowListCreateImage(
            rect,
            .optionIncludingWindow,
            windowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else {
            throw CaptureError.captureFailed
        }

        // kCGWindowName is only populated when Screen Recording permission is
        // granted (which we've already preflighted). Empty titles are common
        // for windows that don't set one — treat those as nil.
        let rawTitle = info[kCGWindowName as String] as? String
        let windowTitle = (rawTitle?.isEmpty == false) ? rawTitle : nil

        return CaptureResult(image: image, appName: appName, windowTitle: windowTitle)
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
    /// edge as a ceiling. For UI screenshots we go smaller: 1280px is still
    /// fully legible (~35% fewer image tokens than 1568) and the OCR pass in
    /// TextExtractor fills in any fine text the model can't re-read visually.
    static func jpegData(
        from cgImage: CGImage,
        maxDimension: CGFloat = 1280,
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
