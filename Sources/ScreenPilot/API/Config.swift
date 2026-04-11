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
    sends you a screenshot of their current screen along with a question about what they're looking \
    at. Answer concisely and practically, referring only to what's actually visible in the image. \
    If the answer depends on something you can't see, say so.
    """
}
