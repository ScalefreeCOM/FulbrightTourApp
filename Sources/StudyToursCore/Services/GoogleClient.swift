import Foundation

public struct MailMessage: Identifiable, Hashable, Sendable {
    public let id: String
    public let threadId: String
    public let from: String
    public let to: String
    public let subject: String
    public let date: Date
    public let snippet: String
    public let body: String
    public let labelIds: [String]
    /// RFC 822 Message-ID and References headers — needed to thread replies in Gmail.
    public var rfcMessageId: String = ""
    public var references: String = ""

    public var fromAddress: String { EmailRules.address(from: from) }
    public var fromName: String { EmailRules.displayName(from: from) }
}

/// Google OAuth (desktop/loopback + PKCE), Gmail, Drive and Calendar.
public final class GoogleClient: @unchecked Sendable {
    public var settings: GoogleSettings
    private var accessToken: String?
    private var labelCache: [String: String] = [:]

    public static let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",     // read + label (sending happens via Salesforce)
        "https://www.googleapis.com/auth/drive",            // shared study tour folders + agenda template copies
        "https://www.googleapis.com/auth/calendar.events",  // tour calendar
        "https://www.googleapis.com/auth/documents",          // read + extend the knowledge base doc
        "https://www.googleapis.com/auth/chat.messages",       // team chat: read + post in the team space
        "https://www.googleapis.com/auth/chat.spaces.readonly", // team chat: list spaces to pick the team space
        "https://www.googleapis.com/auth/directory.readonly",  // team chat: show sender names (Workspace directory)
    ]

    public init(settings: GoogleSettings) { self.settings = settings }

    public var isConnected: Bool { Keychain.get(Keychain.Key.googleRefresh) != nil }
    private var clientId: String { AppConfig.current.googleClientId.isEmpty ? settings.clientId : AppConfig.current.googleClientId }
    private var redirectURI: String { "http://127.0.0.1:\(settings.callbackPort)" }

    // MARK: Auth

    public func connect(openURL: @escaping (URL) -> Void) async throws {
        guard !clientId.isEmpty, Keychain.get(Keychain.Key.googleSecret) != nil else {
            throw AppError("Enter the Google OAuth client ID and secret in Settings first.")
        }
        let pkce = PKCE()
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [.init(name: "client_id", value: clientId),
                        .init(name: "redirect_uri", value: redirectURI),
                        .init(name: "response_type", value: "code"),
                        .init(name: "scope", value: Self.scopes.joined(separator: " ")),
                        .init(name: "code_challenge", value: pkce.challenge),
                        .init(name: "code_challenge_method", value: "S256"),
                        .init(name: "access_type", value: "offline"),
                        .init(name: "prompt", value: "consent")]
        let url = c.url!
        let q = try await LoopbackReceiver(port: settings.callbackPort).waitForCode { openURL(url) }
        guard let code = q["code"] else { throw AppError("No authorization code received") }
        try await token(["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
                         "code_verifier": pkce.verifier])
    }

    public func disconnect() {
        accessToken = nil
        Keychain.set(nil, for: Keychain.Key.googleRefresh)
    }

    private func token(_ extra: [String: String]) async throws {
        var p = extra
        p["client_id"] = clientId
        p["client_secret"] = Keychain.get(Keychain.Key.googleSecret) ?? ""
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = HTTP.formBody(p)
        let obj = try HTTP.json(try await HTTP.send(req, service: "Google auth")) as? [String: Any] ?? [:]
        accessToken = obj["access_token"] as? String
        if let rt = obj["refresh_token"] as? String { Keychain.set(rt, for: Keychain.Key.googleRefresh) }
    }

    private func refresh() async throws {
        guard let rt = Keychain.get(Keychain.Key.googleRefresh) else { throw AppError("Google is not connected.") }
        do {
            try await token(["grant_type": "refresh_token", "refresh_token": rt])
        } catch let e as APIError where e.body.contains("invalid_grant") {
            disconnect()
            throw AppError("Your Google sign-in has expired. Open Settings → Connections and click Connect… again.")
        }
    }

    @discardableResult
    private func call(_ method: String, _ url: String, json: Any? = nil, body: Data? = nil,
                      contentType: String? = nil, retry: Bool = true) async throws -> Any {
        if accessToken == nil { try await refresh() }
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.setValue("Bearer \(accessToken ?? "")", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let body {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        do {
            return try HTTP.json(try await HTTP.send(req, service: "Google"))
        } catch let e as APIError where e.status == 401 && retry {
            try await refresh()
            return try await call(method, url, json: json, body: body, contentType: contentType, retry: false)
        }
    }

    private static func q(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?/:"))) ?? s
    }

    // MARK: Gmail

    public func listMessages(query: String, max: Int = 50) async throws -> [MailMessage] {
        let r = try await call("GET", "https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=\(max)&q=\(Self.q(query))") as? [String: Any] ?? [:]
        let ids = (r["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        var out: [MailMessage] = []
        for id in ids { out.append(try await message(id)) }
        return out
    }

    /// Gmail's estimate of matching messages (cheap; no message bodies fetched).
    public func estimate(query: String) async throws -> Int {
        let r = try await call("GET", "https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=500&q=\(Self.q(query))") as? [String: Any] ?? [:]
        return (r["messages"] as? [[String: Any]])?.count ?? 0
    }

    public func message(_ id: String) async throws -> MailMessage {
        let m = try await call("GET", "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full") as? [String: Any] ?? [:]
        let payload = m["payload"] as? [String: Any] ?? [:]
        var headers: [String: String] = [:]
        for h in payload["headers"] as? [[String: Any]] ?? [] {
            if let n = h["name"] as? String, let v = h["value"] as? String { headers[n.lowercased()] = v }
        }
        let ms = Double(m["internalDate"] as? String ?? "0") ?? 0
        return MailMessage(id: id, threadId: m["threadId"] as? String ?? "", from: headers["from"] ?? "",
                           to: headers["to"] ?? "", subject: headers["subject"] ?? "(no subject)",
                           date: Date(timeIntervalSince1970: ms / 1000), snippet: m["snippet"] as? String ?? "",
                           body: MailBody.extract(payload), labelIds: m["labelIds"] as? [String] ?? [],
                           rfcMessageId: headers["message-id"] ?? "", references: headers["references"] ?? "")
    }

    /// Sends from the signed-in Gmail account (keeps the full thread in Gmail). Returns the Gmail message id.
    @discardableResult
    public func send(raw: String, threadId: String?) async throws -> String {
        var body: [String: Any] = ["raw": raw]
        if let threadId, !threadId.isEmpty { body["threadId"] = threadId }
        let r = try await call("POST", "https://gmail.googleapis.com/gmail/v1/users/me/messages/send", json: body) as? [String: Any] ?? [:]
        return r["id"] as? String ?? ""
    }

    public func labelId(_ name: String) async throws -> String {
        if let id = labelCache[name] { return id }
        let r = try await call("GET", "https://gmail.googleapis.com/gmail/v1/users/me/labels") as? [String: Any] ?? [:]
        for l in r["labels"] as? [[String: Any]] ?? [] {
            if let n = l["name"] as? String, let id = l["id"] as? String { labelCache[n] = id }
        }
        if let id = labelCache[name] { return id }
        let created = try await call("POST", "https://gmail.googleapis.com/gmail/v1/users/me/labels",
                                     json: ["name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"]) as? [String: Any] ?? [:]
        let id = created["id"] as? String ?? ""
        labelCache[name] = id
        return id
    }

    /// Archive = remove from the inbox (labels stay, so it remains findable).
    public func archive(_ messageId: String) async throws {
        try await call("POST", "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageId)/modify", json: ["removeLabelIds": ["INBOX"]])
    }

    public func addLabels(_ messageId: String, names: [String], star: Bool = false) async throws {
        var ids: [String] = []
        for n in names { ids.append(try await labelId(n)) }
        if star { ids.append("STARRED") }
        try await call("POST", "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageId)/modify", json: ["addLabelIds": ids])
    }

    // MARK: Docs

    /// Plain text of a Google Doc the signed-in user can read (e.g. the shared knowledge base).
    public func documentText(id: String) async throws -> String {
        let doc = try await call("GET", "https://docs.googleapis.com/v1/documents/\(id)?includeTabsContent=true") as? [String: Any] ?? [:]
        return KnowledgeBase.text(fromDocument: doc)
    }

    /// Appends text at the end of a Google Doc (first tab).
    public func appendToDocument(id: String, text: String) async throws {
        try await call("POST", "https://docs.googleapis.com/v1/documents/\(id):batchUpdate",
                       json: ["requests": [["insertText": ["endOfSegmentLocation": [String: Any](), "text": text]]]])
    }

    // MARK: Drive

    /// Copies a file (e.g. the agenda template) into a folder. Returns the new file id.
    public func copyFile(_ id: String, name: String, parent: String) async throws -> String {
        let r = try await call("POST", "https://www.googleapis.com/drive/v3/files/\(id)/copy?supportsAllDrives=true",
                               json: ["name": name, "parents": [parent]]) as? [String: Any] ?? [:]
        guard let newId = r["id"] as? String else { throw AppError("Google Drive did not return the copied file") }
        return newId
    }

    public func createFolder(name: String, parent: String? = nil) async throws -> String {
        var meta: [String: Any] = ["name": name, "mimeType": "application/vnd.google-apps.folder"]
        if let parent { meta["parents"] = [parent] }
        let r = try await call("POST", "https://www.googleapis.com/drive/v3/files?supportsAllDrives=true", json: meta) as? [String: Any] ?? [:]
        guard let id = r["id"] as? String else { throw AppError("Google Drive did not return the new folder") }
        return id
    }

    /// Multipart upload. Set `convertTo` to a Google mime type (e.g. a Google Doc) to convert on upload.
    public func upload(name: String, data: Data, mimeType: String, parent: String?, convertTo: String? = nil) async throws -> String {
        var meta: [String: Any] = ["name": name, "mimeType": convertTo ?? mimeType]
        if let parent, !parent.isEmpty { meta["parents"] = [parent] }
        let boundary = "studytours-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(try JSONSerialization.data(withJSONObject: meta))
        body.append("\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--".data(using: .utf8)!)
        let r = try await call("POST", "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart",
                               body: body, contentType: "multipart/related; boundary=\(boundary)") as? [String: Any] ?? [:]
        return r["id"] as? String ?? ""
    }

    /// Replaces the content of an existing file (for Google Docs, the HTML is converted again).
    public func replaceContent(fileId: String, data: Data, mimeType: String) async throws {
        try await call("PATCH", "https://www.googleapis.com/upload/drive/v3/files/\(fileId)?uploadType=media",
                       body: data, contentType: mimeType)
    }

    /// Permanently deletes a file (used by the data-protection scrub).
    public func deleteFile(_ id: String) async throws {
        do { try await call("DELETE", "https://www.googleapis.com/drive/v3/files/\(id)") }
        catch let e as APIError where e.status == 404 {}
    }

    public static func fileURL(_ id: String) -> URL? { URL(string: "https://drive.google.com/open?id=\(id)") }

    // MARK: Chat (team space)

    /// Spaces (not DMs) the signed-in user belongs to.
    public func chatSpaces() async throws -> [ChatSpace] {
        let filter = Self.q("spaceType = \"SPACE\"")
        let r = try await call("GET", "https://chat.googleapis.com/v1/spaces?pageSize=200&filter=\(filter)") as? [String: Any] ?? [:]
        return TeamChat.spaces(fromList: r)
    }

    public func chatSpace(_ space: String) async throws -> ChatSpace {
        let r = try await call("GET", "https://chat.googleapis.com/v1/\(space)") as? [String: Any] ?? [:]
        return TeamChat.spaces(fromList: ["spaces": [r]]).first ?? ChatSpace(id: space, name: space)
    }

    /// The newest messages of a space, oldest first.
    public func chatMessages(space: String, max: Int = 50) async throws -> [ChatMessage] {
        let order = Self.q("createTime desc")
        let r = try await call("GET", "https://chat.googleapis.com/v1/\(space)/messages?pageSize=\(max)&orderBy=\(order)") as? [String: Any] ?? [:]
        return TeamChat.messages(fromList: r)
    }

    /// Posts a message as the signed-in user.
    @discardableResult
    public func postChatMessage(space: String, text: String) async throws -> ChatMessage? {
        let r = try await call("POST", "https://chat.googleapis.com/v1/\(space)/messages", json: ["text": text]) as? [String: Any] ?? [:]
        return TeamChat.message(r)
    }

    /// "users/123" of the signed-in user in that space.
    public func chatMyUserId(space: String) async throws -> String {
        let r = try await call("GET", "https://chat.googleapis.com/v1/\(space)/members/users/me") as? [String: Any] ?? [:]
        return (r["member"] as? [String: Any])?["name"] as? String ?? ""
    }

    /// Display name of a Chat user ("users/123") from the Workspace directory. The Chat API does not return
    /// sender names for user-authenticated calls.
    public func personName(chatUserId: String) async throws -> String {
        let id = chatUserId.replacingOccurrences(of: "users/", with: "")
        let r = try await call("GET", "https://people.googleapis.com/v1/people/\(id)?personFields=names&sources=DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE") as? [String: Any] ?? [:]
        return ((r["names"] as? [[String: Any]])?.first?["displayName"] as? String) ?? ""
    }

    // MARK: Calendar

    /// Creates or updates an event and invites the given attendees (team members).
    public func upsertEvent(calendarId: String, item: AgendaItem, tourName: String, attendees: [String], timeZone: String) async throws -> String {
        let iso = ISO8601DateFormatter()
        let body: [String: Any] = [
            "summary": "\(tourName): \(item.title)",
            "location": item.location,
            "description": item.details,
            "start": ["dateTime": iso.string(from: item.start), "timeZone": timeZone],
            "end": ["dateTime": iso.string(from: item.end), "timeZone": timeZone],
            "attendees": attendees.filter(EmailRules.isValid).map { ["email": $0] },
        ]
        let cal = Self.q(calendarId)
        if let id = item.googleEventId {
            do {
                let r = try await call("PATCH", "https://www.googleapis.com/calendar/v3/calendars/\(cal)/events/\(id)?sendUpdates=all", json: body) as? [String: Any] ?? [:]
                return r["id"] as? String ?? id
            } catch let e as APIError where e.status == 404 || e.status == 410 {}
        }
        let r = try await call("POST", "https://www.googleapis.com/calendar/v3/calendars/\(cal)/events?sendUpdates=all", json: body) as? [String: Any] ?? [:]
        return r["id"] as? String ?? ""
    }

    public func deleteEvent(calendarId: String, eventId: String) async throws {
        do { try await call("DELETE", "https://www.googleapis.com/calendar/v3/calendars/\(Self.q(calendarId))/events/\(eventId)?sendUpdates=all") }
        catch let e as APIError where e.status == 404 || e.status == 410 {}
    }
}

public enum MailBody {
    /// Returns the text/plain part, or stripped text/html as fallback.
    public static func extract(_ payload: [String: Any]) -> String {
        if let t = find(payload, mime: "text/plain") { return t }
        if let h = find(payload, mime: "text/html") { return stripHTML(h) }
        return ""
    }

    private static func find(_ part: [String: Any], mime: String) -> String? {
        if (part["mimeType"] as? String) == mime,
           let data = (part["body"] as? [String: Any])?["data"] as? String,
           let d = PKCE.b64urlDecode(data) {
            return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
        }
        for p in part["parts"] as? [[String: Any]] ?? [] {
            if let t = find(p, mime: mime) { return t }
        }
        return nil
    }

    public static func stripHTML(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes quoted history ("On ... wrote:" / "> ") to keep prompts and logs short.
    public static func stripQuoted(_ body: String) -> String {
        var lines: [Substring] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") { continue }
            if (t.hasPrefix("On ") && t.hasSuffix("wrote:")) || (t.hasPrefix("Am ") && t.hasSuffix("schrieb:")) { break }
            if t.hasPrefix("-----Original Message") || t.hasPrefix("-----Ursprüngliche Nachricht") { break }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
