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

/// Extra context the app can attach to a request.
/// V1 leaves these nil; later work (active window, cursor, etc.) populates them.
struct RequestContext {
    var activeApp: String? = nil
    var activeWindowTitle: String? = nil
    var cursorLocation: CGPoint? = nil
}
