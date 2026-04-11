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

    /// Streaming version of `ask`. Yields incremental text deltas as Claude
    /// produces them. Callers accumulate the deltas themselves — the stream
    /// only emits what's new.
    ///
    /// - Parameters:
    ///   - question: the user's question
    ///   - imageData: encoded screenshot bytes (must be ≤5MB per Anthropic's cap)
    ///   - imageMediaType: MIME type for the image (e.g. "image/jpeg", "image/png")
    ///   - history: previous text-only turns — image blocks should be stripped
    ///     by the caller before passing in, to keep prior screenshots from
    ///     inflating every follow-up request.
    ///   - context: active app / window / OCR context (optional)
    func askStream(
        question: String,
        imageData: Data,
        imageMediaType: String = "image/jpeg",
        history: [ChatMessage] = [],
        context: RequestContext? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let apiKey = Config.anthropicAPIKey
                    guard apiKey != "YOUR_ANTHROPIC_API_KEY_HERE", !apiKey.isEmpty else {
                        throw APIError.missingAPIKey
                    }

                    let request = try Self.buildRequest(
                        endpoint: self.endpoint,
                        apiKey: apiKey,
                        question: question,
                        imageData: imageData,
                        imageMediaType: imageMediaType,
                        history: history,
                        context: context,
                        stream: true
                    )

                    let (bytes, response) = try await self.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw APIError.invalidResponse
                    }
                    if !(200..<300).contains(http.statusCode) {
                        // Collect the error body from the stream so the user
                        // sees the real reason (e.g. 401, 429, overload).
                        var bodyData = Data()
                        for try await byte in bytes {
                            bodyData.append(byte)
                        }
                        let bodyText = String(data: bodyData, encoding: .utf8) ?? "<no body>"
                        throw APIError.http(status: http.statusCode, body: bodyText)
                    }

                    // Anthropic SSE frames: each line is either `event: <name>`
                    // or `data: <json>`, events separated by blank lines. We
                    // only need the JSON payloads — the event-name line is
                    // redundant with the `type` field in the JSON itself.
                    var sawAny = false
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst("data: ".count))
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = json["type"] as? String else {
                            continue
                        }
                        if type == "content_block_delta",
                           let delta = json["delta"] as? [String: Any],
                           (delta["type"] as? String) == "text_delta",
                           let text = delta["text"] as? String {
                            sawAny = true
                            continuation.yield(text)
                        } else if type == "message_stop" {
                            break
                        } else if type == "error",
                                  let err = json["error"] as? [String: Any],
                                  let msg = err["message"] as? String {
                            throw APIError.http(status: 0, body: msg)
                        }
                    }

                    if !sawAny {
                        continuation.yield("(empty response)")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-streaming request. Kept for callers that don't need incremental
    /// output (tests, scripts). Production path uses `askStream`.
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

        let request = try Self.buildRequest(
            endpoint: endpoint,
            apiKey: apiKey,
            question: question,
            imageData: imageData,
            imageMediaType: imageMediaType,
            history: history,
            context: context,
            stream: false
        )

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

    // MARK: - Request building

    private static func buildRequest(
        endpoint: URL,
        apiKey: String,
        question: String,
        imageData: Data,
        imageMediaType: String,
        history: [ChatMessage],
        context: RequestContext?,
        stream: Bool
    ) throws -> URLRequest {
        let base64 = imageData.base64EncodedString()
        let userText = buildUserText(question: question, context: context)
        let currentTurn = ChatMessage(
            role: .user,
            content: [
                .image(base64: base64, mediaType: imageMediaType),
                .text(userText)
            ]
        )
        let messages = history + [currentTurn]

        var body: [String: Any] = [
            "model": Config.claudeModel,
            "max_tokens": Config.maxTokens,
            "system": Config.systemPrompt,
            "messages": messages.map(Self.encode)
        ]
        if stream { body["stream"] = true }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        if stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
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

    /// Assemble the user-facing text block: a structured context header
    /// (active app, window title, OCR text) followed by the raw question.
    /// Kept in the user turn rather than the system prompt so the system
    /// prompt stays static — a prerequisite for prompt caching later.
    private static func buildUserText(question: String, context: RequestContext?) -> String {
        guard let context = context else { return question }

        var header = ""
        if let app = context.activeApp {
            header += "Active app: \(app)\n"
        }
        if let title = context.activeWindowTitle {
            header += "Active window: \(title)\n"
        }
        if let screenText = context.screenText, !screenText.isEmpty {
            header += "\nText extracted from the screenshot via OCR (authoritative for exact "
            header += "strings, code, and error messages):\n"
            header += "```\n\(screenText)\n```\n"
        }

        if header.isEmpty { return question }
        return "\(header)\n---\n\(question)"
    }
}

private struct MessageResponse: Decodable {
    let content: [ContentItem]
    struct ContentItem: Decodable {
        let type: String
        let text: String?
    }
}
