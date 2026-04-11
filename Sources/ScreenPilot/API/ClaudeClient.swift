import Foundation

enum APIError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case http(status: Int, body: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Anthropic API key is missing. Set ANTHROPIC_API_KEY or edit Config.swift."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .http(let status, let body):
            return "HTTP \(status): \(body)"
        case .decoding(let detail):
            return "Failed to decode response: \(detail)"
        }
    }
}

final class ClaudeClient {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Ask Claude a question about a screenshot.
    ///
    /// - Parameters:
    ///   - question: the user's question
    ///   - imageData: encoded screenshot bytes (must be ≤5MB per Anthropic's cap)
    ///   - imageMediaType: MIME type for the image (e.g. "image/jpeg", "image/png")
    ///   - history: previous messages (empty in v1; wired for future session memory)
    ///   - context: additional context fields (empty in v1; wired for future work)
    func ask(
        question: String,
        imageData: Data,
        imageMediaType: String = "image/jpeg",
        history: [ChatMessage] = [],
        context: RequestContext? = nil
    ) async throws -> String {
        let apiKey = Config.anthropicAPIKey
        guard apiKey != "YOUR_ANTHROPIC_API_KEY_HERE", !apiKey.isEmpty else {
            throw APIError.missingAPIKey
        }

        let base64 = imageData.base64EncodedString()
        let currentTurn = ChatMessage(
            role: .user,
            content: [
                .image(base64: base64, mediaType: imageMediaType),
                .text(question)
            ]
        )
        let messages = history + [currentTurn]

        let body: [String: Any] = [
            "model": Config.claudeModel,
            "max_tokens": Config.maxTokens,
            "system": systemPromptIncludingContext(context),
            "messages": messages.map(Self.encode)
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<no body>"
            throw APIError.http(status: http.statusCode, body: bodyText)
        }

        do {
            let decoded = try JSONDecoder().decode(MessageResponse.self, from: data)
            let text = decoded.content
                .compactMap { $0.type == "text" ? $0.text : nil }
                .joined(separator: "\n")
            return text.isEmpty ? "(empty response)" : text
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    // MARK: - Encoding

    private static func encode(_ message: ChatMessage) -> [String: Any] {
        let content: [[String: Any]] = message.content.map { block in
            switch block {
            case .text(let text):
                return ["type": "text", "text": text]
            case .image(let base64, let mediaType):
                return [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": mediaType,
                        "data": base64
                    ]
                ]
            }
        }
        return ["role": message.role.rawValue, "content": content]
    }

    private func systemPromptIncludingContext(_ context: RequestContext?) -> String {
        // V1: just the base prompt. Future context fields get appended here
        // without changing the call sites.
        guard let context = context else { return Config.systemPrompt }
        var lines = [Config.systemPrompt]
        if let app = context.activeApp {
            lines.append("Active app: \(app)")
        }
        if let title = context.activeWindowTitle {
            lines.append("Active window: \(title)")
        }
        return lines.joined(separator: "\n\n")
    }
}

private struct MessageResponse: Decodable {
    let content: [ContentItem]
    struct ContentItem: Decodable {
        let type: String
        let text: String?
    }
}
