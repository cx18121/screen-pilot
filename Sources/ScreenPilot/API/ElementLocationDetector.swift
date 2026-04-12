import AppKit
import CoreGraphics
import Foundation

/// One-shot grounding pass: asks Claude (via the Computer Use beta tool) to
/// point at the specific UI element the user is asking about. Runs in parallel
/// with the main chat stream; failure is silent by design so it never blocks
/// or degrades the text answer.
///
/// We use the Computer Use tool rather than a plain vision call because it
/// activates a pixel-counting training that's materially more accurate at
/// coordinate extraction than the general image-understanding path.
final class ElementLocationDetector {
    struct DetectedLocation {
        /// Pixel coordinate in the resized image we sent, top-left origin.
        let point: CGPoint
        /// Dimensions of the image we sent — i.e. the coordinate space `point`
        /// is expressed in. Callers divide by these to get a 0–1 fraction of
        /// the captured region.
        let declaredWidth: Int
        let declaredHeight: Int
    }

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fires a single non-streaming request. Returns nil on any failure, on
    /// timeout, or when Claude decides the question has no specific visual
    /// target (in which case it replies with plain text and no tool_use).
    func detect(question: String, image: CGImage) async -> DetectedLocation? {
        let apiKey = Config.anthropicAPIKey
        guard apiKey != "YOUR_ANTHROPIC_API_KEY_HERE", !apiKey.isEmpty else {
            return nil
        }

        let (declaredW, declaredH) = Self.bestComputerUseResolution(
            sourceWidth: image.width,
            sourceHeight: image.height
        )

        guard let jpeg = Self.resizeAsJPEG(
            image: image,
            targetWidth: declaredW,
            targetHeight: declaredH,
            quality: 0.8
        ) else {
            return nil
        }

        let base64 = jpeg.base64EncodedString()

        let prompt = """
        The user asked: "\(question)"

        If this question refers to a specific visible element on the screen \
        (a button, icon, menu item, text field, error, or small region), use \
        the computer tool with action "left_click" and the coordinate of that \
        element's center. Pick the single most relevant element. If the \
        question is about the screen as a whole, or not about any specific \
        visible element, reply with the plain text "no specific element" and \
        do not call any tool.
        """

        let body: [String: Any] = [
            "model": Config.claudeModel,
            "max_tokens": 256,
            "tools": [[
                "type": "computer_20251124",
                "name": "computer",
                "display_width_px": declaredW,
                "display_height_px": declaredH
            ]],
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": base64
                        ]
                    ] as [String: Any],
                    ["type": "text", "text": prompt] as [String: Any]
                ]
            ]]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("computer-use-2025-11-24", forHTTPHeaderField: "anthropic-beta")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return nil
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return nil
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            return nil
        }

        for block in content {
            guard (block["type"] as? String) == "tool_use",
                  let input = block["input"] as? [String: Any],
                  let coord = input["coordinate"] as? [Any],
                  coord.count == 2,
                  let rawX = Self.asDouble(coord[0]),
                  let rawY = Self.asDouble(coord[1]) else {
                continue
            }
            let x = max(0, min(Double(declaredW), rawX))
            let y = max(0, min(Double(declaredH), rawY))
            return DetectedLocation(
                point: CGPoint(x: x, y: y),
                declaredWidth: declaredW,
                declaredHeight: declaredH
            )
        }
        return nil
    }

    // MARK: - Helpers

    /// Pick a Computer Use resolution whose aspect ratio best matches the
    /// source. Anthropic's canonical sizes are 1024×768 (4:3), 1280×800 (16:10,
    /// most Retina Macs), and 1366×768 (16:9). Choosing the closest match
    /// avoids X/Y distortion that would offset returned coordinates.
    static func bestComputerUseResolution(
        sourceWidth: Int,
        sourceHeight: Int
    ) -> (width: Int, height: Int) {
        let options: [(w: Int, h: Int)] = [
            (1024, 768),
            (1280, 800),
            (1366, 768)
        ]
        let source = Double(sourceWidth) / Double(max(1, sourceHeight))
        var best = options[1]
        var bestDelta = Double.infinity
        for opt in options {
            let ratio = Double(opt.w) / Double(opt.h)
            let delta = abs(ratio - source)
            if delta < bestDelta {
                bestDelta = delta
                best = opt
            }
        }
        return (best.w, best.h)
    }

    /// Resize a CGImage to exact pixel dimensions and JPEG-encode it.
    ///
    /// Uses a CGContext with explicit width/height rather than
    /// `NSImage.lockFocus()` — the latter silently produces a 2× bitmap on
    /// Retina displays, which would make the image Claude sees twice the
    /// declared dimensions and return coordinates in the wrong scale.
    static func resizeAsJPEG(
        image: CGImage,
        targetWidth: Int,
        targetHeight: Int,
        quality: CGFloat
    ) -> Data? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
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
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let resized = ctx.makeImage() else { return nil }

        let rep = NSBitmapImageRep(cgImage: resized)
        return rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: quality]
        )
    }

    private static func asDouble(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}
