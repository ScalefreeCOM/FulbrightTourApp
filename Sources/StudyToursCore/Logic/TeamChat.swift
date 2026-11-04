import Foundation

/// A message in the team's Google Chat space.
public struct ChatMessage: Identifiable, Hashable, Sendable {
    public let id: String          // "spaces/…/messages/…"
    public let senderId: String    // "users/…"
    public var senderName: String
    public let text: String
    public let created: Date
    public let isBot: Bool

    public init(id: String, senderId: String, senderName: String, text: String, created: Date, isBot: Bool = false) {
        self.id = id; self.senderId = senderId; self.senderName = senderName
        self.text = text; self.created = created; self.isBot = isBot
    }
}

public struct ChatSpace: Identifiable, Hashable, Sendable {
    public let id: String          // "spaces/…"
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Google Chat (team coordination). The app posts and reads as the signed-in Google user — no bot.
public enum TeamChat {

    /// Accepts "spaces/AAAA", "AAAA" or a Google Chat URL
    /// (https://mail.google.com/chat/u/0/#chat/space/AAAA, https://chat.google.com/room/AAAA).
    /// Returns "spaces/AAAA", or "" if nothing usable was entered.
    public static func spaceName(from input: String) -> String {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        for marker in ["/space/", "/room/", "spaces/"] {
            if let r = s.range(of: marker, options: .backwards) {
                let id = s[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
                return id.isEmpty ? "" : "spaces/\(id)"
            }
        }
        let id = s.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return id.count == s.count ? "spaces/\(id)" : ""
    }

    public static func webURL(space: String) -> URL? {
        let id = space.replacingOccurrences(of: "spaces/", with: "")
        return id.isEmpty ? nil : URL(string: "https://mail.google.com/chat/u/0/#chat/space/\(id)")
    }

    /// Parses a `spaces.messages.list` response; returns messages oldest first.
    public static func messages(fromList json: [String: Any]) -> [ChatMessage] {
        (json["messages"] as? [[String: Any]] ?? []).compactMap(message).sorted { $0.created < $1.created }
    }

    public static func message(_ m: [String: Any]) -> ChatMessage? {
        guard let id = m["name"] as? String else { return nil }
        let sender = m["sender"] as? [String: Any] ?? [:]
        let text = (m["text"] as? String) ?? (m["argumentText"] as? String) ?? ""
        let created = (m["createTime"] as? String).flatMap(parseDate) ?? Date.distantPast
        return ChatMessage(id: id, senderId: sender["name"] as? String ?? "",
                           senderName: sender["displayName"] as? String ?? "",
                           text: text, created: created, isBot: (sender["type"] as? String) == "BOT")
    }

    public static func spaces(fromList json: [String: Any]) -> [ChatSpace] {
        (json["spaces"] as? [[String: Any]] ?? []).compactMap { s in
            guard let id = s["name"] as? String else { return nil }
            return ChatSpace(id: id, name: (s["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// RFC 3339 with or without fractional seconds (Google returns up to nanoseconds).
    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // trim nanoseconds to milliseconds
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let frac = s[s.index(after: dot)..<end].prefix(3)
            if let d = f.date(from: String(s[..<dot]) + "." + frac + String(s[end...])) { return d }
        }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
