import Foundation

enum Config {
    /// Anthropic API key. Resolution order:
    ///   1. ANTHROPIC_API_KEY environment variable (works for `swift run`)
    ///   2. ~/.config/screenpilot/api_key (works when launched via `open`,
    ///      since LaunchServices does not forward the shell environment)
    ///   3. Hardcoded placeholder (edit this file as a last resort)
    static var anthropicAPIKey: String {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty {
            return env
        }
        let path = ("~/.config/screenpilot/api_key" as NSString).expandingTildeInPath
        if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "YOUR_ANTHROPIC_API_KEY_HERE"
    }

    static let claudeModel = "claude-sonnet-4-6"
    static let anthropicAPIVersion = "2023-06-01"
    static let maxTokens = 2048

    static let systemPrompt = """
    You are ScreenPilot, a screen-aware assistant running on the user's Mac. Each turn, the user \
    sends a screenshot of their focused window along with a question about it. A short context \
    header may identify the active app and window title. OCR-extracted text from the screen may \
    also be included — trust it over the image for exact strings, code, filenames, and error \
    messages (OCR is more reliable than visually re-reading pixels).

    Answer guidelines:
    - Be terse: ≤4 sentences unless the user asks for detail, steps, or a longer explanation.
    - Reference only what is actually visible in the image or the extracted text. If the answer \
    depends on something you cannot see, say so plainly — do not guess.
    - Skip preamble ("Sure!", "I can see that…"). Lead with the answer.
    - Use fenced code blocks for code, commands, paths, and error messages.
    - If the user's question is ambiguous, answer the most likely interpretation in one line, then \
    ask a single clarifying question.
    """
}
