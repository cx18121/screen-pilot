import Foundation

/// A single turn in a Claude conversation.
/// Kept as a plain value type so the API client and future conversation memory
/// layer can both operate on it without coupling.
struct ChatMessage {
    enum Role: String { case user, assistant }

    let role: Role
    let content: [ContentBlock]
}

enum ContentBlock {
    case text(String)
    case image(base64: String, mediaType: String)
}

/// Extra context the app can attach to a request. Surfaced to the model as a
/// structured header prepended to the user's question.
struct RequestContext {
    var activeApp: String? = nil
    var activeWindowTitle: String? = nil
    var cursorLocation: CGPoint? = nil
    var screenText: String? = nil
    /// Pruned AX tree of the focused window. Different trust level from OCR —
    /// authoritative for control roles, labels, and geometry; not always
    /// available (Electron without AX, games, etc.). See AXExtractor.
    var axTree: String? = nil
}
