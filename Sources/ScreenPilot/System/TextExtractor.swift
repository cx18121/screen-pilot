import Foundation
import Vision
import CoreGraphics

/// On-device OCR via the Vision framework. Runs synchronously on the calling
/// thread — fast enough for screenshots (<300ms typical) and avoids the
/// complexity of an async wrapper for a single request.
enum TextExtractor {
    /// Extract text from a screenshot. Returns nil if OCR fails or yields too
    /// little signal to bother sending to the model (threshold keeps noise like
    /// isolated menu bar characters from inflating the prompt).
    static func extractText(from cgImage: CGImage, minCharacters: Int = 20) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let joined = lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.count >= minCharacters ? joined : nil
    }
}
