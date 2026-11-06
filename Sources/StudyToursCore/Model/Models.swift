import Foundation

// MARK: - Phases

/// The seven phases of a study tour. Deadlines are expressed relative to the
/// tour start date ("T"), so a plan can be reused for any tour.
public enum PhaseID: Int, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case setup = 0, outreach, program, registration, submissions, tour, wrapup

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .setup: return "Setup"
        case .outreach: return "Host Outreach & Confirmation"
        case .program: return "Program & Promotion"
        case .registration: return "Registration & Data Quality"
        case .submissions: return "Host Submissions & Logistics"
        case .tour: return "Tour Days"
        case .wrapup: return "Wrap-up & Data Protection"
        }
    }

    public var shortTitle: String {
        switch self {
        case .setup: return "Setup"
        case .outreach: return "Host Outreach"
        case .program: return "Program & Promotion"
        case .registration: return "Registration"
        case .submissions: return "Submissions & Logistics"
        case .tour: return "Tour Days"
        case .wrapup: return "Wrap-up"
        }
    }

    /// Value of the Task phase picklist (mapping key task.phaseValues, in phase order).
    public var salesforceValue: String {
        let values = SFMap.list("task.phaseValues")
        return rawValue < values.count ? values[rawValue] : "\(rawValue)"
    }

    public init?(salesforceValue v: String) {
        guard let i = SFMap.list("task.phaseValues").firstIndex(of: v), let p = PhaseID(rawValue: i) else { return nil }
        self = p
    }

    public var systemImage: String {
        switch self {
        case .setup: return "gearshape.2"
        case .outreach: return "building.columns"
        case .program: return "megaphone"
        case .registration: return "person.crop.rectangle.stack"
        case .submissions: return "tablecells"
        case .tour: return "bus"
        case .wrapup: return "lock.shield"
        }
    }

    public var summary: String {
        switch self {
        case .setup: return "Create the tour, assign team roles, create the Drive folder and link the Salesforce program."
        case .outreach: return "Contact host institutions, track confirmations and capture which participant data each host needs."
        case .program: return "Tentative and final agenda, flyer, two marketing waves, FAQ for the email assistant."
        case .registration: return "Registrations come in as members of the tour program. Cleanse data and validate passports continuously."
        case .submissions: return "Fill each host's attendee form (attached to the Opportunity) and send it to the visit's recipient; restaurants, city tour, final briefing."
        case .tour: return "Attendance and emergency lists; urgent-only inbox."
        case .wrapup: return "Thank-you emails to officials (own program), media report, and deletion of passport data with an audit log."
        }
    }

    /// Default window, in days relative to tour start (end of tour for wrap-up is handled by the plan).
    public var defaultWindow: ClosedRange<Int> {
        switch self {
        case .setup: return -110 ... -100
        case .outreach: return -100 ... -62
        case .program: return -80 ... -30
        case .registration: return -76 ... -32
        case .submissions: return -31 ... -1
        case .tour: return 0 ... 0
        case .wrapup: return 1 ... 30
        }
    }
}

// MARK: - Team

public struct TeamMember: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var email: String
    public var roles: [String]

    public init(name: String, email: String, roles: [String]) {
        self.name = name; self.email = email; self.roles = roles
    }
}

public enum TeamRole {
    public static let all = ["Lead", "Coordination", "Letter", "Contacts", "Registrations",
                             "Marketing", "Media", "Restaurants", "City Tour", "Panel", "Data Protection"]
}

// MARK: - Tasks

public struct TaskItem: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var phase: PhaseID
    public var title: String
    public var role: String
    /// Due date relative to tour start in days (negative = before the tour).
    public var offsetDays: Int
    public var done: Bool = false
    public var notes: String = ""
    /// Set when the item is a Salesforce Task on the program.
    public var salesforceId: String?
    public var ownerId: String?
    public var ownerName: String?
    /// Absolute due date (Salesforce ActivityDate); falls back to offsetDays.
    public var dueDate: Date?

    public init(phase: PhaseID, title: String, role: String, offsetDays: Int) {
        self.phase = phase; self.title = title; self.role = role; self.offsetDays = offsetDays
    }
}

// MARK: - Hosts (Salesforce Accounts + Contacts)

public enum HostStatus: String, Codable, CaseIterable, Sendable {
    case identified = "Identified"
    case letterSent = "Letter sent"
    case confirmed = "Confirmed"
    case declined = "Declined"
    case submitted = "List submitted"
}

public struct HostContact: Codable, Identifiable, Hashable, Sendable {
    public var id: String          // Salesforce Contact Id
    public var name: String
    public var email: String
    public var title: String

    public init(id: String, name: String, email: String, title: String) {
        self.id = id; self.name = name; self.email = email; self.title = title
    }
}

public struct ExportRecord: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var fileName: String
    public var createdAt: Date
    public var localPath: String?
    public var driveFileId: String?
    public var containsPassportData: Bool
    public var participantCount: Int
    public var deletedAt: Date?

    public init(fileName: String, createdAt: Date, localPath: String?, driveFileId: String?,
                containsPassportData: Bool, participantCount: Int) {
        self.fileName = fileName; self.createdAt = createdAt; self.localPath = localPath
        self.driveFileId = driveFileId; self.containsPassportData = containsPassportData
        self.participantCount = participantCount
    }
}

public struct Host: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var accountId: String?       // Salesforce Account Id
    public var name: String
    public var contacts: [HostContact] = []
    public var status: HostStatus = .identified
    public var visitDate: Date?
    public var submissionDeadline: Date?
    /// Columns of the participant list this host requires, in order.
    public var requiredFields: [ParticipantField] = ParticipantField.defaultHostExport
    /// Optional custom column headers (e.g. German labels).
    public var columnHeaders: [ParticipantField: String] = [:]
    public var notes: String = ""
    public var exports: [ExportRecord] = []

    public init(name: String, accountId: String? = nil) {
        self.name = name; self.accountId = accountId
    }

    public func header(for field: ParticipantField) -> String {
        if let h = columnHeaders[field], !h.trimmingCharacters(in: .whitespaces).isEmpty { return h }
        return field.label
    }

    /// Email domains of the host's contacts — used to recognise official mail.
    public var emailDomains: Set<String> {
        Set(contacts.compactMap { c in
            c.email.split(separator: "@").last.map { $0.lowercased() }
        }.filter { !EmailRules.freemailDomains.contains($0) })
    }
}

// MARK: - Host visits (Salesforce Opportunities linked to the program)

public struct HostVisit: Identifiable, Hashable, Sendable {
    public var id: String                 // Opportunity Id
    public var name: String
    public var stage: String
    public var accountId: String?
    public var organization: String
    public var visitStart: Date?
    public var visitEnd: Date?
    public var listDeadline: Date?
    public var recipientId: String?
    public var recipientName: String
    public var recipientEmail: String
    public var recipientGreeting: String

    public init(id: String, name: String, stage: String, accountId: String?, organization: String,
                visitStart: Date?, visitEnd: Date?, listDeadline: Date?, recipientId: String?,
                recipientName: String, recipientEmail: String, recipientGreeting: String) {
        self.id = id; self.name = name; self.stage = stage; self.accountId = accountId; self.organization = organization
        self.visitStart = visitStart; self.visitEnd = visitEnd; self.listDeadline = listDeadline; self.recipientId = recipientId
        self.recipientName = recipientName; self.recipientEmail = recipientEmail; self.recipientGreeting = recipientGreeting
    }

    public var isConfirmed: Bool { stage == SFMap["hostVisit.stageConfirmed"] }
    public var isDeclined: Bool { stage == SFMap["hostVisit.stageDeclined"] }

    /// Host status in study-tour terms (Opportunity stages from the mapping).
    public var statusLabel: String {
        if stage == SFMap["hostVisit.stageIdentified"] { return "Identified" }
        if stage == SFMap["hostVisit.stageLetterSent"] { return "Letter sent" }
        if SFMap.list("hostVisit.stagesInDiscussion").contains(stage) { return "In discussion" }
        if isConfirmed { return "Confirmed" }
        if isDeclined { return "Declined" }
        return stage
    }
}

public struct SalesforceFile: Identifiable, Hashable, Sendable {
    public var id: String                 // ContentVersion Id (latest)
    public var title: String
    public var fileExtension: String
    public var modified: Date?
    public init(id: String, title: String, fileExtension: String, modified: Date?) {
        self.id = id; self.title = title; self.fileExtension = fileExtension; self.modified = modified
    }
}

// MARK: - Programs (Salesforce Campaigns, labelled "Program" in the org)

public struct LinkedProgram: Codable, Identifiable, Hashable, Sendable {
    public var id: String          // Campaign Id
    public var name: String
    public var purpose: String     // e.g. "Thank-you officials"
    public init(id: String, name: String, purpose: String) { self.id = id; self.name = name; self.purpose = purpose }
}

// MARK: - Participants (Salesforce Leads, labelled "Member" in the org)

public enum ParticipantField: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable, Hashable, Sendable {
    case firstName, lastName, email, phone, organization, title
    case birthDate, nationality
    case identificationType, passportNumber, passportExpiry, passportIssuingCountry
    case dietary, emergencyContact, emergencyPhone

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .firstName: return "First name"
        case .lastName: return "Last name"
        case .email: return "Email"
        case .phone: return "Phone"
        case .organization: return "Organization"
        case .title: return "Position"
        case .birthDate: return "Date of birth"
        case .nationality: return "Citizenship"
        case .identificationType: return "ID type"
        case .passportNumber: return "Passport / ID number"
        case .passportExpiry: return "ID expiry date"
        case .passportIssuingCountry: return "Issuing country"
        case .dietary: return "Dietary needs"
        case .emergencyContact: return "Emergency contact"
        case .emergencyPhone: return "Emergency phone"
        }
    }

    public var germanLabel: String {
        switch self {
        case .firstName: return "Vorname"
        case .lastName: return "Nachname"
        case .email: return "E-Mail"
        case .phone: return "Telefon"
        case .organization: return "Organisation"
        case .title: return "Funktion"
        case .birthDate: return "Geburtsdatum"
        case .nationality: return "Staatsangehörigkeit"
        case .identificationType: return "Ausweisart"
        case .passportNumber: return "Ausweis-/Passnummer"
        case .passportExpiry: return "Gültig bis"
        case .passportIssuingCountry: return "Ausstellungsstaat"
        case .dietary: return "Ernährung"
        case .emergencyContact: return "Notfallkontakt"
        case .emergencyPhone: return "Notfalltelefon"
        }
    }

    /// Lead (Member) API field name from the Salesforce mapping (config/salesforce-mapping*.json).
    public var defaultSalesforceField: String { SFMap["member.\(rawValue)"] }

    /// Identity-document data that must be deleted after the tour.
    public var isPassportData: Bool {
        switch self {
        case .birthDate, .nationality, .identificationType, .passportNumber, .passportExpiry, .passportIssuingCountry:
            return true
        default: return false
        }
    }

    /// Third-party personal data only needed during the tour — deleted together with passport data.
    public var isEmergencyData: Bool { self == .emergencyContact || self == .emergencyPhone }

    /// Everything the after-tour deletion can clear.
    public var isDeletableAfterTour: Bool { isPassportData || isEmergencyData }

    public var isDate: Bool { self == .birthDate || self == .passportExpiry }

    public static let defaultHostExport: [ParticipantField] =
        [.lastName, .firstName, .birthDate, .nationality, .passportNumber]

    /// Fields cleared by the default scrub.
    public static let defaultScrub: [ParticipantField] =
        [.birthDate, .identificationType, .passportNumber, .passportExpiry, .passportIssuingCountry, .emergencyContact, .emergencyPhone]
}

public struct Participant: Identifiable, Hashable, Sendable {
    public var id: String            // Salesforce Lead Id
    public var values: [ParticipantField: String]

    public init(id: String, values: [ParticipantField: String]) {
        self.id = id; self.values = values
    }

    public subscript(_ f: ParticipantField) -> String {
        get { values[f] ?? "" }
        set { values[f] = newValue }
    }

    public var displayName: String {
        let n = "\(self[.firstName]) \(self[.lastName])".trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? id : n
    }
}

// MARK: - Settings (non-secret; secrets live in the Keychain)

public struct SalesforceSettings: Codable, Hashable, Sendable {
    /// The organisation's production org (from the config file) — all users connect here.
    public static var productionURL: String { AppConfig.current.salesforceURL }
    public var loginURL: String { Self.productionURL }
    /// Consumer key from the config file; the Settings value is only used if the config has none.
    public var effectiveClientId: String {
        AppConfig.current.salesforceConsumerKey.isEmpty ? clientId : AppConfig.current.salesforceConsumerKey
    }
    public var clientId: String = ""
    public var apiVersion: String = "v62.0"
    public var callbackPort: Int = 8765
    public var fieldMap: [ParticipantField: String] =
        Dictionary(uniqueKeysWithValues: ParticipantField.allCases.map { ($0, $0.defaultSalesforceField) })
    /// Extra SOQL filter for Leads when no campaign is linked, e.g. `LeadSource = 'Study Tour 2026'`.
    public var leadFilter: String = ""

    public init() {}

    /// Fixed field names of the production org (stored mappings from earlier versions are ignored).
    public func field(_ f: ParticipantField) -> String { f.defaultSalesforceField }
}

public struct GoogleSettings: Codable, Hashable, Sendable {
    public var clientId: String = ""
    public var callbackPort: Int = 8766
    public var inboxQuery: String = "in:inbox newer_than:14d"
    public var importantLabel: String = "Study Tour/Important"
    public var answeredLabel: String = "Study Tour/Answered"
    /// Team chat space ("spaces/…"), chosen in Settings. Empty = default from the config file.
    public var chatSpace: String = ""
    public var chatSpaceTitle: String = ""
    public init() {}

    /// Tolerant: settings saved by older versions lack newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GoogleSettings()
        clientId = try c.decodeIfPresent(String.self, forKey: .clientId) ?? d.clientId
        callbackPort = try c.decodeIfPresent(Int.self, forKey: .callbackPort) ?? d.callbackPort
        inboxQuery = try c.decodeIfPresent(String.self, forKey: .inboxQuery) ?? d.inboxQuery
        importantLabel = try c.decodeIfPresent(String.self, forKey: .importantLabel) ?? d.importantLabel
        answeredLabel = try c.decodeIfPresent(String.self, forKey: .answeredLabel) ?? d.answeredLabel
        chatSpace = try c.decodeIfPresent(String.self, forKey: .chatSpace) ?? d.chatSpace
        chatSpaceTitle = try c.decodeIfPresent(String.self, forKey: .chatSpaceTitle) ?? d.chatSpaceTitle
    }

    /// The team chat space in use: chosen in Settings, else the config default.
    public var effectiveChatSpace: String {
        chatSpace.isEmpty ? TeamChat.spaceName(from: AppConfig.current.googleChatSpace) : chatSpace
    }
}

public struct GeminiSettings: Codable, Hashable, Sendable {
    public var model: String = "gemini-2.5-flash"
    public var redactNumbers: Bool = true
    public init() {}
}

public struct AssistantSettings: Codable, Hashable, Sendable {
    public var autoSend: Bool = false
    public var autoSendMaxPerRun: Int = 10
    public var pollMinutes: Int = 15
    public var signature: String = "Kind regards,\nThe Fulbright Study Tour Team"
    public var tone: String = "friendly, concise, professional"
    public var urgentKeywords: [String] = ["urgent", "dringend", "deadline", "frist", "cancel", "absage",
                                           "visa", "security", "sicherheit", "passport", "reisepass", "complaint"]
    public init() {}
}

public struct CleansingSettings: Codable, Hashable, Sendable {
    public var defaultCountryCallingCode: String = "+49"
    public var passportMinValidityMonths: Int = 6
    public init() {}
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var salesforce = SalesforceSettings()
    public var google = GoogleSettings()
    public var gemini = GeminiSettings()
    public var assistant = AssistantSettings()
    public var cleansing = CleansingSettings()
    public init() {}
}

// MARK: - Agenda / calendar

public enum AgendaKind: String, Codable, CaseIterable, Sendable {
    case visit = "Host visit"
    case meal = "Restaurant"
    case cityTour = "City tour"
    case travel = "Travel"
    case teamMeeting = "Team meeting"
    case other = "Other"
}

/// One calendar entry. Synced to Salesforce (Event), Google Calendar and the agenda Google Doc.
public struct AgendaItem: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var title: String
    public var kind: AgendaKind = .visit
    public var start: Date
    public var end: Date
    public var location: String = ""
    public var hostId: UUID?
    public var details: String = ""
    /// Show in the participant-facing agenda doc (team meetings usually are internal).
    public var publicItem: Bool = true
    public var salesforceEventId: String?
    public var googleEventId: String?
    public var lastSynced: Date?
    public var modified: Date = Date()

    public init(title: String, kind: AgendaKind, start: Date, end: Date) {
        self.title = title; self.kind = kind; self.start = start; self.end = end
    }

    public var needsSync: Bool { lastSynced.map { $0 < modified } ?? true }
}

// MARK: - Tour

public struct ScrubLogEntry: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var date: Date
    public var action: String
    public var detail: String
    public var count: Int

    public init(date: Date, action: String, detail: String, count: Int) {
        self.date = date; self.action = action; self.detail = detail; self.count = count
    }
}

public struct Tour: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var city: String = ""
    public var startDate: Date
    public var endDate: Date
    public var campaignId: String = ""
    public var campaignName: String = ""
    /// Additional programs (child Campaigns), e.g. for the thank-you mailing to officials.
    public var programs: [LinkedProgram] = []
    public var driveFolderId: String = ""
    public var team: [TeamMember] = []
    public var tasks: [TaskItem]
    public var hosts: [Host] = []
    public var links: [String] = []
    public var agenda: [AgendaItem] = []
    public var agendaDocId: String = ""
    public var googleCalendarId: String = "primary"
    /// Facts about the tour that the email assistant may use (agenda, meeting points, FAQ).
    public var knowledgeBase: String = ""
    public var scrubLog: [ScrubLogEntry] = []
    public var handledMessageIds: [String] = []

    public init(name: String, startDate: Date, endDate: Date) {
        self.name = name; self.startDate = startDate; self.endDate = endDate
        self.tasks = PhasePlan.defaultTasks()
    }

    // Tolerant decoding: data written by other app versions (team mates) must still load.
    enum CodingKeys: String, CodingKey {
        case id, name, city, startDate, endDate, campaignId, campaignName, programs, driveFolderId, team, tasks,
             hosts, links, agenda, agendaDocId, googleCalendarId, knowledgeBase, scrubLog, handledMessageIds
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Study Tour"
        city = try c.decodeIfPresent(String.self, forKey: .city) ?? ""
        startDate = try c.decodeIfPresent(Date.self, forKey: .startDate) ?? Date()
        endDate = try c.decodeIfPresent(Date.self, forKey: .endDate) ?? startDate
        campaignId = try c.decodeIfPresent(String.self, forKey: .campaignId) ?? ""
        campaignName = try c.decodeIfPresent(String.self, forKey: .campaignName) ?? ""
        programs = try c.decodeIfPresent([LinkedProgram].self, forKey: .programs) ?? []
        driveFolderId = try c.decodeIfPresent(String.self, forKey: .driveFolderId) ?? ""
        team = try c.decodeIfPresent([TeamMember].self, forKey: .team) ?? []
        tasks = try c.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? PhasePlan.defaultTasks()
        hosts = try c.decodeIfPresent([Host].self, forKey: .hosts) ?? []
        links = try c.decodeIfPresent([String].self, forKey: .links) ?? []
        agenda = try c.decodeIfPresent([AgendaItem].self, forKey: .agenda) ?? []
        agendaDocId = try c.decodeIfPresent(String.self, forKey: .agendaDocId) ?? ""
        googleCalendarId = try c.decodeIfPresent(String.self, forKey: .googleCalendarId) ?? "primary"
        knowledgeBase = try c.decodeIfPresent(String.self, forKey: .knowledgeBase) ?? ""
        scrubLog = try c.decodeIfPresent([ScrubLogEntry].self, forKey: .scrubLog) ?? []
        handledMessageIds = try c.decodeIfPresent([String].self, forKey: .handledMessageIds) ?? []
    }

    public func dueDate(_ task: TaskItem, calendar: Calendar = .current) -> Date {
        if let d = task.dueDate { return d }
        let base = task.phase == .wrapup ? endDate : startDate
        return calendar.date(byAdding: .day, value: task.offsetDays, to: base) ?? base
    }

    public func window(_ phase: PhaseID, calendar: Calendar = .current) -> (Date, Date) {
        let w = phase.defaultWindow
        if phase == .tour { return (startDate, endDate) }
        let base = phase == .wrapup ? endDate : startDate
        return (calendar.date(byAdding: .day, value: w.lowerBound, to: base) ?? base,
                calendar.date(byAdding: .day, value: w.upperBound, to: base) ?? base)
    }

    public func progress(_ phase: PhaseID) -> Double {
        let t = tasks.filter { $0.phase == phase }
        guard !t.isEmpty else { return 0 }
        return Double(t.filter(\.done).count) / Double(t.count)
    }
}
