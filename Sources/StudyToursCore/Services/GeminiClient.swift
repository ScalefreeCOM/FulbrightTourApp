import Foundation

/// Google Gemini (Generative Language API) with an API key from the Keychain.
public final class GeminiClient: @unchecked Sendable {
    public var settings: GeminiSettings
    /// Called when Google retired the configured model and the client switched to the successor it named.
    public var onModelChanged: (@Sendable (String) -> Void)?
    /// Called with the total tokens (prompt + answer) of every successful request.
    public var onUsage: (@Sendable (Int) -> Void)?
    public init(settings: GeminiSettings) { self.settings = settings }

    public var isConfigured: Bool { !(Keychain.get(Keychain.Key.geminiKey) ?? "").isEmpty }

    private func request(_ path: String, method: String = "GET", body: Any? = nil) async throws -> Any {
        guard let key = Keychain.get(Keychain.Key.geminiKey), !key.isEmpty else {
            throw AppError("Enter a Gemini API key in Settings.")
        }
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/\(path)")!)
        req.httpMethod = method
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try HTTP.json(try await HTTP.send(req, service: "Gemini"))
    }

    public func generate(system: String, prompt: String, json: Bool, temperature: Double = 0.2) async throws -> String {
        var config: [String: Any] = ["temperature": temperature]
        if json { config["responseMimeType"] = "application/json" }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": config,
        ]
        let r: [String: Any]
        do {
            r = try await request("models/\(settings.model):generateContent", method: "POST", body: body) as? [String: Any] ?? [:]
        } catch let e as APIError where e.status == 404 {
            // Google retires models ("… no longer available … use models/X"): switch to the named successor once.
            guard let next = Self.successorModel(in: e.body), next != settings.model else { throw e }
            settings.model = next
            onModelChanged?(next)
            r = try await request("models/\(next):generateContent", method: "POST", body: body) as? [String: Any] ?? [:]
        }
        if let usage = r["usageMetadata"] as? [String: Any], let total = usage["totalTokenCount"] as? Int { onUsage?(total) }
        let parts = ((r["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AppError("Gemini returned no text (possibly blocked by safety filters).") }
        return text
    }

    /// The model Google recommends in a "model not available" error, e.g. "use models/gemini-3.1-pro-preview".
    public static func successorModel(in errorBody: String) -> String? {
        guard let r = errorBody.range(of: #"use models/([A-Za-z0-9.\-]+)"#, options: .regularExpression) else { return nil }
        let name = errorBody[r].replacingOccurrences(of: "use models/", with: "")
        return name.isEmpty ? nil : name
    }

    public func listModels() async throws -> [String] {
        let r = try await request("models?pageSize=200") as? [String: Any] ?? [:]
        return (r["models"] as? [[String: Any]] ?? []).compactMap { m in
            guard let methods = m["supportedGenerationMethods"] as? [String], methods.contains("generateContent"),
                  let name = m["name"] as? String else { return nil }
            return name.replacingOccurrences(of: "models/", with: "")
        }.sorted()
    }
}
