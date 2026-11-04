import Foundation

/// Facts the email assistant may use. Lives in a Google Doc referenced by the program's
/// `Knowledge_Base__c` field (default: the shared knowledge base for all study tours).
public enum KnowledgeBase {
    public static var programField: String { SFMap["program.knowledgeBase"] }
    /// Shared default knowledge base (from the config file).
    public static var defaultURL: String { AppConfig.current.knowledgeBaseURL }

    struct NewFacts: Decodable { let newFacts: [String] }

    /// Prompt: which general facts from the team's (human-approved) reply are not yet in the knowledge base?
    public static func learningPrompt(question: String, answer: String, knowledgeBase: String) -> (system: String, prompt: String) {
        let system = """
        You maintain the knowledge base of the Fulbright study tour team: confirmed, general facts used to answer attendees.
        From the team's reply below, extract facts that are (1) general and reusable for other attendees or future tours,
        (2) NOT already contained in the knowledge base, and (3) free of personal data (no names of attendees, no emails,
        phone numbers, ID numbers or individual circumstances). Write each fact as one short, self-contained English sentence.
        If there is nothing new, return an empty list. Respond ONLY with JSON: {"newFacts": [string]}
        """
        let prompt = """
        KNOWLEDGE BASE:
        \(knowledgeBase.prefix(20000))

        ATTENDEE QUESTION:
        \(Assistant.redact(question).prefix(3000))

        TEAM REPLY (approved):
        \(Assistant.redact(answer).prefix(3000))
        """
        return (system, prompt)
    }

    public static func parseFacts(_ json: String) -> [String] {
        (Assistant.decode(NewFacts.self, from: json)?.newFacts ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // no emails, no ID/passport/phone-like numbers (same detection as the redaction)
            .filter { !$0.isEmpty && $0.range(of: #"[^\s@]+@[^\s@]+\.[a-z]{2,}"#, options: [.regularExpression, .caseInsensitive]) == nil
                      && Assistant.redact($0) == $0 }
    }

    /// Text block appended to the knowledge base doc.
    public static func appendix(facts: [String], date: Date = Date()) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        return "\n\nAdded from email replies (\(df.string(from: date))):\n" + facts.map { "• \($0)" }.joined(separator: "\n") + "\n"
    }

    /// Extracts the document id from any Google Docs URL (…/document/d/<id>/edit?tab=…).
    public static func documentId(from url: String) -> String? {
        guard let r = url.range(of: #"/document/d/([A-Za-z0-9_-]{10,})"#, options: .regularExpression) else { return nil }
        return String(url[r].dropFirst("/document/d/".count))
    }

    /// Plain text of a Google Docs API `documents.get` response (all tabs, paragraphs and tables).
    public static func text(fromDocument doc: [String: Any]) -> String {
        var out = ""
        func walk(_ content: [[String: Any]]) {
            for el in content {
                if let p = el["paragraph"] as? [String: Any] {
                    for e in p["elements"] as? [[String: Any]] ?? [] {
                        if let t = (e["textRun"] as? [String: Any])?["content"] as? String { out += t }
                    }
                } else if let table = el["table"] as? [String: Any] {
                    for row in table["tableRows"] as? [[String: Any]] ?? [] {
                        for cell in row["tableCells"] as? [[String: Any]] ?? [] {
                            walk(cell["content"] as? [[String: Any]] ?? [])
                            out += "\t"
                        }
                        out += "\n"
                    }
                }
            }
        }
        func walkTabs(_ tabs: [[String: Any]]) {
            for tab in tabs {
                if let title = (tab["tabProperties"] as? [String: Any])?["title"] as? String, tabs.count > 1 { out += "\n## \(title)\n" }
                walk(((tab["documentTab"] as? [String: Any])?["body"] as? [String: Any])?["content"] as? [[String: Any]] ?? [])
                walkTabs(tab["childTabs"] as? [[String: Any]] ?? [])
            }
        }
        if let tabs = doc["tabs"] as? [[String: Any]], !tabs.isEmpty { walkTabs(tabs) }
        else { walk((doc["body"] as? [String: Any])?["content"] as? [[String: Any]] ?? []) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
