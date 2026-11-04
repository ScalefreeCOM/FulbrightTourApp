import Foundation

/// Builds RFC 5322 messages for the Gmail API (`raw`, base64url).
public enum MailComposer {
    public struct Attachment: Sendable {
        public let fileName: String
        public let mimeType: String
        public let data: Data
        public init(fileName: String, mimeType: String, data: Data) { self.fileName = fileName; self.mimeType = mimeType; self.data = data }
        public static let xlsxMime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    }

    /// Message with attachments (multipart/mixed).
    public static func raw(to: String, subject: String, body: String, attachments: [Attachment],
                           inReplyTo: String? = nil, references: String? = nil) -> String {
        guard !attachments.isEmpty else { return raw(to: to, subject: subject, body: body, inReplyTo: inReplyTo, references: references) }
        let boundary = "studytours-\(UUID().uuidString)"
        var headers = ["To: \(to)", "Subject: \(encodeHeader(subject))", "MIME-Version: 1.0",
                       "Content-Type: multipart/mixed; boundary=\"\(boundary)\""]
        if let inReplyTo, !inReplyTo.isEmpty {
            headers.append("In-Reply-To: \(inReplyTo)")
            headers.append("References: \([references ?? "", inReplyTo].filter { !$0.isEmpty }.joined(separator: " "))")
        }
        let b64: (Data) -> String = { $0.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) }
        var parts = ["--\(boundary)\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(b64(Data(body.utf8)))"]
        for a in attachments {
            let name = encodeHeader(a.fileName)
            parts.append("--\(boundary)\r\nContent-Type: \(a.mimeType); name=\"\(name)\"\r\nContent-Disposition: attachment; filename=\"\(name)\"\r\nContent-Transfer-Encoding: base64\r\n\r\n\(b64(a.data))")
        }
        let message = headers.joined(separator: "\r\n") + "\r\n\r\n" + parts.joined(separator: "\r\n") + "\r\n--\(boundary)--"
        return PKCE.b64url(Data(message.utf8))
    }

    public static func raw(to: String, subject: String, body: String,
                           inReplyTo: String? = nil, references: String? = nil) -> String {
        var headers = [
            "To: \(to)",
            "Subject: \(encodeHeader(subject))",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: base64",
        ]
        if let inReplyTo, !inReplyTo.isEmpty {
            headers.append("In-Reply-To: \(inReplyTo)")
            let refs = [references ?? "", inReplyTo].filter { !$0.isEmpty }.joined(separator: " ")
            headers.append("References: \(refs)")
        }
        let encodedBody = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let message = headers.joined(separator: "\r\n") + "\r\n\r\n" + encodedBody
        return PKCE.b64url(Data(message.utf8))
    }

    /// RFC 2047 encoded-word for non-ASCII header values (e.g. umlauts in subjects).
    public static func encodeHeader(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { !$0.isASCII }) else { return s }
        return "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }
}
