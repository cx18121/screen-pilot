import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenshotCapture {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case captureFailed
        case noDisplayAvailable

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
            case .noDisplayAvailable:
                return "No display available for capture."
            }
        }
    }

    /// Result of a capture, bundling the image with window metadata that the
    /// coordinator forwards to the model as context.
    struct CaptureResult {
        let image: CGImage
        let appName: String?
        let windowTitle: String?
        /// PID of the frontmost application at capture time. Used by the AX
        /// extractor to pull the focused window's accessibility tree — we
        /// stash it here so the coordinator doesn't have to re-query
        /// NSWorkspace and race with app switches.
        let pid: pid_t?
        /// Region the image covers, in the window server's global coordinate
        /// system (top-left origin, points). Needed to map Computer-Use-returned
        /// coordinates back onto the physical screen for the highlight overlay.
        let screenFrame: CGRect
    }

    /// Captures the frontmost window of the active application, with metadata.
    /// Falls back to full-screen capture if no suitable window is found (e.g.
    /// Finder desktop, fullscreen game). Menu bar, dock, and other apps'
    /// windows are excluded — the model sees only what the user is focused on.
    static func captureFocusedWindow() async throws -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontPID = frontApp?.processIdentifier
        let appName = frontApp?.localizedName

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.permissionDenied
        }

        // SCShareableContent.windows is documented to be in front-to-back
        // z-order. Pick the topmost normal-layer window owned by the frontmost
        // app that's big enough to be real content (not a tooltip/menu).
        let target = content.windows.first { window in
            guard let pid = frontPID,
                  window.owningApplication?.processID == pid else {
                return false
            }
            if window.windowLayer != 0 { return false }
            if window.frame.width < 200 || window.frame.height < 200 { return false }
            return true
        }

        guard let window = target else {
            let (image, frame) = try await captureDisplay(content: content)
            return CaptureResult(
                image: image,
                appName: appName,
                windowTitle: nil,
                pid: frontPID,
                screenFrame: frame
            )
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = makeConfiguration(for: filter)

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw CaptureError.captureFailed
        }

        // SCWindow.title is only populated when Screen Recording permission is
        // granted (which we've already preflighted). Empty titles are common
        // for windows that don't set one — treat those as nil.
        let rawTitle = window.title
        let windowTitle = (rawTitle?.isEmpty == false) ? rawTitle : nil

        return CaptureResult(
            image: image,
            appName: appName,
            windowTitle: windowTitle,
            pid: frontPID,
            screenFrame: window.frame
        )
    }

    /// Captures the entire primary display as a CGImage.
    ///
    /// We preflight Screen Recording permission explicitly so we can surface a
    /// useful error instead of silently sending a wallpaper-only screenshot
    /// (ScreenCaptureKit would throw, but the preflight message is clearer).
    static func captureFullScreen() async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.permissionDenied
        }
        let (image, _) = try await captureDisplay(content: content)
        return image
    }

    private static func captureDisplay(content: SCShareableContent) async throws -> (CGImage, CGRect) {
        guard let display = content.displays.first else {
            throw CaptureError.noDisplayAvailable
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = makeConfiguration(for: filter)
        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return (image, display.frame)
        } catch {
            throw CaptureError.captureFailed
        }
    }

    private static func makeConfiguration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // contentRect is in points; multiply by pointPixelScale to get native
        // pixel dimensions — equivalent to the old .bestResolution flag.
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int(filter.contentRect.width * scale))
        config.height = max(1, Int(filter.contentRect.height * scale))
        config.showsCursor = false
        return config
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
