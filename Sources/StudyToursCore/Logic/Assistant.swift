import Foundation

// MARK: - Types

public enum SenderKind: String, Codable, Sendable {
    case official = "Official"     // Salesforce Contact / host domain — never auto-answered
    case attendee = "Attendee"     // Salesforce Lead
    case team = "Team"
    case unknown = "Unknown"
}

public struct SenderIdentity: Hashable, Sendable {
    public var kind: SenderKind
    public var record: SFRecordRef?
    public var source: String
    public init(kind: SenderKind, record: SFRecordRef?, source: String) {
        self.kind = kind; self.record = record; self.source = source
    }
}

public struct MailTriage: Codable, Hashable, Sendable {
    public var relatedToTour: Bool
    public var senderType: String          // attendee | official | other
    public var importance: String          // high | normal | low
    public var needsReply: Bool
    public var topic: String
    public var reason: String
    public var firstName: String?
    public var lastName: String?
    public var organization: String?
    public var jobTitle: String?
    /// The sender holds an official role or is the person the group visits (not an assistant or office staff).
    public var vip: Bool?
    /// Salutation for letters to the sender, in the language and formality of their mail.
    public var greeting: String?

    public var isHigh: Bool { importance.lowercased() == "high" }
}

public struct DraftReply: Codable, Hashable, Sendable {
    public var subject: String?
    public var body: String
    public var confident: Bool
    public var missingInfo: [String]?
}

public struct RecordProposal: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case lead = "Lead", contact = "Contact + Account"
        /// Name shown in the app (Salesforce UI labels: Member, Contact, Organization).
        public var displayName: String { self == .lead ? "member" : "contact" }
    }
    public var id: String { messageId }
    public let messageId: String
    public var kind: Kind
    public var firstName: String
    public var lastName: String
    public var email: String
    public var organization: String
    public var jobTitle: String
    public var existingAccount: SFRecordRef?
    public var possibleDuplicates: [SFRecordRef]
    /// Set the Contact's VIP flag (suggested by the assistant, editable before creating).
    public var vip: Bool = false
    /// Salutation in letters (required on Contacts in the Fulbright org).
    public var greeting: String = ""

    /// Safe to create without a human: nobody with this name already exists.
    public var isClean: Bool { possibleDuplicates.isEmpty && !lastName.isEmpty }
}

// MARK: - Assistant logic (pure, testable)

public enum Assistant {

    // MARK: Redaction before data leaves for Gemini

    /// Masks long alphanumeric tokens containing several digits (passport/ID/phone/IBAN-like).
    public static func redact(_ s: String) -> String {
        let pattern = #"(?i)\b(?=[A-Z0-9]*\d[A-Z0-9]*\d[A-Z0-9]*\d[A-Z0-9]*\d)[A-Z0-9]{6,}\b"#
        return s.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
    }

    // MARK: Sender identification (deterministic, before any AI)

    public static func identify(address: String, tour: Tour, salesforceMatches: [SFRecordRef]) -> SenderIdentity {
        let a = address.lowercased()
        if salesforceMatches.contains(where: { $0.kind == .user }) {
            return SenderIdentity(kind: .team, record: nil, source: "team member")
        }
        if let c = salesforceMatches.first(where: { $0.kind == .contact }) {
            return SenderIdentity(kind: .official, record: c, source: "contact in the database")
        }
        if tour.hosts.contains(where: { h in h.contacts.contains { $0.email.lowercased() == a } }) {
            return SenderIdentity(kind: .official, record: nil, source: "Host contact")
        }
        let domain = a.split(separator: "@").last.map(String.init) ?? ""
        if !domain.isEmpty, tour.hosts.contains(where: { $0.emailDomains.contains(domain) }) {
            return SenderIdentity(kind: .official, record: nil, source: "Host email domain")
        }
        if let l = salesforceMatches.first(where: { $0.kind == .lead }) {
            return SenderIdentity(kind: .attendee, record: l, source: "member in the database")
        }
        return SenderIdentity(kind: .unknown, record: nil, source: "not in the database")
    }

    public static func hasUrgentKeyword(_ m: MailMessage, keywords: [String]) -> Bool {
        let text = (m.subject + " " + m.snippet).lowercased()
        return keywords.contains { !$0.isEmpty && text.contains($0.lowercased()) }
    }

    public static func isAutomated(_ address: String) -> Bool {
        let a = address.lowercased()
        return ["noreply", "no-reply", "donotreply", "do-not-reply", "mailer-daemon", "postmaster", "notifications@", "bounce"]
            .contains { a.contains($0) }
    }

    // MARK: Tour context for the model

    public static func tourContext(_ tour: Tour, knowledgeBase: String = "") -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        let dd = DateFormatter(); dd.dateStyle = .long
        var s = "Study tour: \(tour.name)\nCity: \(tour.city)\nDates: \(dd.string(from: tour.startDate)) – \(dd.string(from: tour.endDate))\n"
        let items = tour.agenda.filter(\.publicItem).sorted { $0.start < $1.start }
        if !items.isEmpty {
            s += "\nAgenda:\n" + items.map { "- \(df.string(from: $0.start)): \($0.title)\($0.location.isEmpty ? "" : " @ \($0.location)")" }.joined(separator: "\n")
        }
        if !knowledgeBase.isEmpty { s += "\n\nKnowledge base (confirmed facts for all study tours):\n\(knowledgeBase.prefix(20000))" }
        return s
    }

    // MARK: Prompts

    public static func triagePrompt(_ m: MailMessage, identity: SenderIdentity, tour: Tour, knowledgeBase: String = "", redact doRedact: Bool) -> (system: String, prompt: String) {
        let system = """
        You triage the mailbox of a member of the volunteer team that organises Fulbright study tours.
        Senders are either attendees/participants of a study tour, officials of institutions the tour visits \
        (or their assistants), team members, or unrelated (newsletters, spam, other topics).
        Respond ONLY with JSON matching:
        {"relatedToTour": bool, "senderType": "attendee"|"official"|"other", "importance": "high"|"normal"|"low",
         "needsReply": bool, "topic": string (max 8 words), "reason": string (max 25 words),
         "firstName": string|null, "lastName": string|null, "organization": string|null, "jobTitle": string|null,
         "vip": bool, "greeting": string|null}
        importance=high for: anything from officials or their offices, deadlines, security/visa/registration \
        requirements from hosts, cancellations, schedule changes, complaints, emergencies.
        Extract the sender's name, organisation and job title from the signature if present.
        vip=true only if the sender personally holds an official role (e.g. ambassador, minister, member of parliament, \
        commissioner, director-general, head of unit, mayor) or is the person the group visits or meets. \
        vip=false for assistants, secretaries, office or protocol staff writing on someone's behalf, attendees and everyone else.
        greeting = the salutation for a letter to the sender, matching the language and formality of their email \
        and ending with a colon in English or a comma in German, e.g. "Dear Jane:", "Dear Ms. Doe:", "Sehr geehrter Herr Doe,".
        """
        let body = String(MailBody.stripQuoted(m.body).prefix(6000))
        let prompt = """
        Known context: sender lookup = \(identity.kind.rawValue) (\(identity.source)).
        \(tourContext(tour).prefix(3000))

        --- EMAIL ---
        From: \(m.from)
        Subject: \(m.subject)
        Date: \(m.date)

        \(doRedact ? redact(body) : body)
        """
        return (system, prompt)
    }

    /// "Reply all" CCs: the original To and Cc recipients, without the sender and the team's own mailbox.
    public static func replyCC(_ m: MailMessage, ownAddress: String) -> [String] {
        var seen: Set<String> = [m.fromAddress, ownAddress.lowercased()]
        return (EmailRules.addresses(from: m.to) + EmailRules.addresses(from: m.cc)).filter { seen.insert($0).inserted }
    }

    /// Sign-off under a draft: "Best regards," and the first name of the Salesforce user who writes.
    public static func signOff(_ name: String) -> String { "Best regards,\n\(name)" }

    /// First name for the sign-off ("Michael Olschimke" → "Michael"); the team if the user is unknown.
    public static func signOffName(userName: String?) -> String {
        let first = (userName ?? "").split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "The Fulbright Study Tour Team" : first
    }

    /// Full name for the sign-off to officials; the team if the user is unknown.
    public static func signOffFullName(userName: String?) -> String {
        let n = (userName ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "The Fulbright Study Tour Team" : n
    }

    /// Makes sure a draft ends with a closing and the writer's name (Gemini sometimes leaves it out).
    /// `accept` lists other names that also count as signed (e.g. the first name for an official on first-name terms).
    public static func ensureSignOff(_ body: String, name: String, accept: [String] = []) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = trimmed.split(separator: "\n").suffix(3).map { $0.trimmingCharacters(in: .whitespaces) }
        return tail.contains { ([name] + accept).contains($0) } ? trimmed : trimmed + "\n\n" + signOff(name)
    }

    /// Members are signed with the first name; officials with the full name unless the thread shows first-name terms.
    public static func replyPrompt(_ m: MailMessage, sender: SenderKind = .attendee, greeting: String? = nil,
                                   signOffName: String = "", signOffFullName: String = "",
                                   tour: Tour, knowledgeBase: String = "", settings: AssistantSettings, redact doRedact: Bool) -> (system: String, prompt: String) {
        let closing = "End the body with a closing in the language of the email (e.g. \"Best regards,\" or \"Viele Grüße,\")"
        let closingRule: String
        if signOffName.isEmpty {
            closingRule = "End the body with a closing such as \"Best regards,\"."
        } else if sender == .official, !signOffFullName.isEmpty, signOffFullName != signOffName {
            closingRule = """
            \(closing) and the full name "\(signOffFullName)" on the next line. Only if the earlier messages in this thread \
            show that the official and the writer are on first-name terms (the official addresses them by first name, or \
            earlier replies were signed "\(signOffName)"), sign with "\(signOffName)" instead.
            """
        } else {
            closingRule = "\(closing) and the name \"\(signOffName)\" on the next line."
        }
        let greetingRule = greeting.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            .map { "Start the body with exactly this greeting line: \"\($0)\"" }
            ?? "Start the body with a greeting line that fits the sender and the language, e.g. \"Dear Jane,\" or \"Dear Ms. Doe,\"."
        let who: String
        switch sender {
        case .official: who = """
            an official of an institution the tour visits, or their office. Write formally and respectfully, \
            address them with their title, and do not commit the team to anything that is not in the tour context.
            """
        case .attendee: who = "an attendee of the study tour."
        default: who = "someone writing about the study tour (not yet known in Salesforce)."
        }
        let system = """
        You draft replies to emails on behalf of the volunteer team that organises a Fulbright study tour. \
        A team member reviews and sends every draft. The sender is \(who)
        Tone: \(settings.tone). Reply in the language of the incoming email.
        Use ONLY facts from the tour context. Never invent dates, times, places, prices or promises.
        If the answer needs information you do not have, set "confident" to false, list it in "missingInfo", \
        and put a placeholder like [CHECK: what is missing] in the body.
        Never ask anyone to send passport numbers or other ID data by email.
        \(greetingRule)
        \(closingRule) Do not add anything after the name.
        Respond ONLY with JSON: {"subject": string, "body": string, "confident": bool, "missingInfo": [string]}
        """
        let parts = MailBody.split(m.body)
        let body = String(parts.new.prefix(6000))
        // for officials the earlier thread shows how formal the relationship is (greeting and sign-off)
        let history = sender == .official ? String(parts.quoted.prefix(4000)) : ""
        let prompt = """
        TOUR CONTEXT:
        \(tourContext(tour, knowledgeBase: knowledgeBase))

        --- EMAIL FROM \(sender == .official ? "OFFICIAL" : sender == .attendee ? "ATTENDEE" : "SENDER") ---
        From: \(m.fromName)
        Subject: \(m.subject)

        \(doRedact ? redact(body) : body)
        \(history.isEmpty ? "" : "\n--- EARLIER MESSAGES IN THIS THREAD ---\n" + (doRedact ? redact(history) : history))
        """
        return (system, prompt)
    }

    // MARK: Parsing

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "^```(json)?\\s*", with: "", options: .regularExpression)
                 .replacingOccurrences(of: "\\s*```$", with: "", options: .regularExpression)
        }
        if let s = t.firstIndex(of: "{"), let e = t.lastIndex(of: "}") { t = String(t[s...e]) }
        return try? JSONDecoder().decode(T.self, from: Data(t.utf8))
    }

    public static func replySubject(_ original: String) -> String {
        let lower = original.lowercased()
        return lower.hasPrefix("re:") || lower.hasPrefix("aw:") ? original : "Re: \(original)"
    }

    /// Fixed line directly below the writer's name on every outgoing mail (not a setting).
    public static let sentVia = "via https://scalefr.ee/fulbrightapp"

    /// Footer of every outgoing mail: the "via" line right under the name, then the user's Gmail signature.
    /// Applied once — a body that already contains the "via" line is returned unchanged.
    public static func withFooter(_ body: String, signature: String = "") -> String {
        if body.contains(sentVia) { return body }
        let sig = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + sentVia + (sig.isEmpty ? "" : "\n\n" + sig)
    }

    /// The reply as sent: the draft (ending with the sign-off), the footer and the quoted original.
    public static func composeBody(_ reply: String, signature: String = "", original: MailMessage) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        let quoted = MailBody.stripQuoted(original.body).split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(40).map { "> " + $0 }.joined(separator: "\n")
        return withFooter(reply, signature: signature) + "\n\nOn \(df.string(from: original.date)), \(original.fromName) wrote:\n\(quoted)"
    }

    // MARK: Record proposals (new Leads / Contacts)

    /// Returns a proposal only for tour-related mail from people not yet in Salesforce (by email).
    public static func recordProposal(_ m: MailMessage, triage: MailTriage, identity: SenderIdentity) -> RecordProposal? {
        guard triage.relatedToTour, identity.kind == .unknown, !isAutomated(m.fromAddress) else { return nil }
        let kind: RecordProposal.Kind
        switch triage.senderType {
        case "attendee": kind = .lead
        case "official": kind = .contact
        default: return nil
        }
        return proposal(m, kind: kind, triage: triage)
    }

    /// Proposal for any sender the user wants to add by hand ("Add sender to Salesforce"),
    /// whether or not the assistant found the mail tour-related. Officials become Contacts, everyone else a member (Lead).
    public static func manualProposal(_ m: MailMessage, triage: MailTriage?) -> RecordProposal {
        proposal(m, kind: triage?.senderType == "official" ? .contact : .lead, triage: triage)
    }

    private static func proposal(_ m: MailMessage, kind: RecordProposal.Kind, triage: MailTriage?) -> RecordProposal {
        var first = triage?.firstName ?? "", last = triage?.lastName ?? ""
        if last.isEmpty {
            let parts = m.fromName.split(separator: " ").map(String.init)
            if parts.count >= 2, !m.fromName.contains("@") { first = parts.dropLast().joined(separator: " "); last = parts.last! }
            else if parts.count == 1, !m.fromName.contains("@") { last = parts[0] }
        }
        return RecordProposal(messageId: m.id, kind: kind, firstName: Names.normalize(first), lastName: Names.normalize(last),
                              email: m.fromAddress, organization: triage?.organization ?? "", jobTitle: triage?.jobTitle ?? "",
                              existingAccount: nil, possibleDuplicates: [], vip: kind == .contact && triage?.vip == true,
                              greeting: defaultGreeting(suggested: triage?.greeting, firstName: Names.normalize(first)))
    }

    /// The assistant's suggestion, else the org's usual "Dear <first name>:".
    public static func defaultGreeting(suggested: String?, firstName: String) -> String {
        if let g = suggested?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty { return String(g.prefix(100)) }
        return firstName.isEmpty ? "To whom it may concern:" : "Dear \(firstName):"
    }

    // MARK: Team digest (Google Chat)

    public static func teamDigest(_ tour: Tour, today: Date = Date(), horizonDays: Int = 14) -> String {
        let df = DateFormatter(); df.dateFormat = "EEE dd.MM."
        let cal = Calendar.current
        let horizon = cal.date(byAdding: .day, value: horizonDays, to: today)!
        let open = tour.tasks.filter { !$0.done }
        let overdue = open.filter { tour.dueDate($0) < cal.startOfDay(for: today) }.sorted { tour.dueDate($0) < tour.dueDate($1) }
        let upcoming = open.filter { let d = tour.dueDate($0); return d >= cal.startOfDay(for: today) && d <= horizon }
            .sorted { tour.dueDate($0) < tour.dueDate($1) }
        var s = "*\(tour.name)* – status \(df.string(from: today))\n"
        if !overdue.isEmpty {
            s += "\n⚠️ Overdue:\n" + overdue.map { "• \($0.title) (due \(df.string(from: tour.dueDate($0))))" }.joined(separator: "\n") + "\n"
        }
        if !upcoming.isEmpty {
            s += "\n📅 Next \(horizonDays) days:\n" + upcoming.map { "• \(df.string(from: tour.dueDate($0))) \($0.title)" }.joined(separator: "\n") + "\n"
        }
        let confirmed = tour.hosts.filter { $0.status == .confirmed || $0.status == .submitted }.count
        s += "\n🏛 Hosts confirmed: \(confirmed)/\(tour.hosts.count)"
        if overdue.isEmpty && upcoming.isEmpty { s += "\n✅ Nothing due in the next \(horizonDays) days." }
        return s
    }
}
