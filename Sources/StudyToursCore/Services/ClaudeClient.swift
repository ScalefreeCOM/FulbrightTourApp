import Foundation

/// Anthropic Claude (Messages API over HTTPS — there is no official Swift SDK) with an API key from the Keychain.
/// Same `generate` contract as `GeminiClient`, so the assistant can use either provider.
public final class ClaudeClient: @unchecked Sendable {
    public var settings: ClaudeSettings
    /// Total tokens (input + output) of each request, for the usage display.
    public var onUsage: (@Sendable (Int) -> Void)?
    public init(settings: ClaudeSettings) { self.settings = settings }

    static let apiVersion = "2026-10-21"

    public var isConfigured: Bool { !(Keychain.get(Keychain.Key.claudeKey) ?? "").isEmpty }

    private func request(_ path: String, method: String = "GET", body: Any? = nil, beta: String? = nil) async throws -> Any {
        guard let key = Keychain.get(Keychain.Key.claudeKey), !key.isEmpty else {
            throw AppError("Enter a Claude API key in Settings.")
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/\(path)")!)
        req.httpMethod = method
        req.timeoutInterval = 300
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if let beta { req.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try HTTP.json(try await HTTP.send(req, service: "Claude"))
    }

    /// Request body for one prompt. `temperature` is not sent: current Claude models reject sampling parameters.
    /// If a safety classifier declines, the API retries on a fallback model it picks ("fallbacks": "default").
    static func body(model: String, effort: String, system: String, prompt: String, json: Bool) -> [String: Any] {
        let sys = json ? system + "\n\nAnswer with a single JSON object only — no Markdown, no code fences, no text before or after it." : system
        return [
            "model": model,
            "max_tokens": 16000,
            "system": sys,
            "messages": [["role": "user", "content": prompt]],
            "output_config": ["effort": effort],
            "fallbacks": "default",
        ]
    }

    public func generate(system: String, prompt: String, json: Bool, temperature: Double = 0.2) async throws -> String {
        let r = try await request("messages", method: "POST",
                                  body: Self.body(model: settings.model, effort: settings.effort, system: system, prompt: prompt, json: json),
                                  beta: "server-side-fallback-2026-07-01") as? [String: Any] ?? [:]
        if let u = r["usage"] as? [String: Any] {
            onUsage?((u["input_tokens"] as? Int ?? 0) + (u["output_tokens"] as? Int ?? 0))
        }
        return try Self.text(from: r, json: json)
    }

    /// The answer text of a Messages API response (text blocks only — thinking blocks are skipped).
    static func text(from r: [String: Any], json: Bool) throws -> String {
        switch r["stop_reason"] as? String {
        case "refusal":
            throw AppError("Claude declined this request (safety filter). Write this reply yourself.")
        case "max_tokens":
            throw AppError("Claude's answer was cut off (too long). Try again.")
        default: break
        }
        let blocks = r["content"] as? [[String: Any]] ?? []
        var text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if json { text = stripCodeFence(text) }
        guard !text.isEmpty else { throw AppError("Claude returned no text.") }
        return text
    }

    /// Removes a ```json … ``` wrapper if the model added one anyway.
    static func stripCodeFence(_ s: String) -> String {
        guard s.hasPrefix("```") else { return s }
        var lines = s.components(separatedBy: "\n")
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Model ids available to the key (Models API).
    public func listModels() async throws -> [String] {
        let r = try await request("models?limit=100") as? [String: Any] ?? [:]
        return (r["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }
}

/// The AI provider the assistant uses (mail drafts, triage, host-form recognition) — Gemini or Claude, chosen in Settings.
public final class AIService: @unchecked Sendable {
    public let gemini: GeminiClient
    public let claude: ClaudeClient
    public var provider: AIProvider

    public init(gemini: GeminiClient, claude: ClaudeClient, provider: AIProvider) {
        self.gemini = gemini; self.claude = claude; self.provider = provider
    }

    public var name: String { provider.rawValue }
    public var isConfigured: Bool { provider == .claude ? claude.isConfigured : gemini.isConfigured }

    public func generate(system: String, prompt: String, json: Bool, temperature: Double = 0.2) async throws -> String {
        provider == .claude
            ? try await claude.generate(system: system, prompt: prompt, json: json, temperature: temperature)
            : try await gemini.generate(system: system, prompt: prompt, json: json, temperature: temperature)
    }

    public func listModels() async throws -> [String] {
        provider == .claude ? try await claude.listModels() : try await gemini.listModels()
    }
}
