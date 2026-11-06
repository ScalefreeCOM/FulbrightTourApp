import Foundation

/// Maps what the app needs ("member.birthDate", "hostVisit.stageConfirmed" …) to the API names and picklist
/// values of a concrete Salesforce org.
///
/// Defaults match the metadata package in `salesforce/` (and the Fulbright org). An organisation whose org is
/// configured differently copies `config/salesforce-mapping.default.json` to `config/salesforce-mapping.json`
/// and changes only the entries that differ — missing entries fall back to the defaults.
/// Lists (e.g. phase values) are written as JSON arrays.
public enum SFMap {

    /// Compiled-in defaults (group → key → value). `config/salesforce-mapping.default.json` mirrors this.
    public static let defaults: [String: [String: Any]] = [
        "member": [            // object: Lead (labelled "Member" in the Fulbright org)
            "firstName": "FirstName", "lastName": "LastName", "email": "Email", "phone": "MobilePhone",
            "organization": "Company", "title": "Title",
            "birthDate": "Birth_Date__c", "nationality": "Citizenship__c",
            "identificationType": "Identification_Type__c", "passportNumber": "Identification_Number__c",
            "passportExpiry": "Expiry_Date__c", "passportIssuingCountry": "Issuing_Country__c",
            "dietary": "Dietary_Needs__c", "emergencyContact": "Emergency_Contact_Name__c",
            "emergencyPhone": "Emergency_Contact_Phone__c",
            "leadSource": "LeadSource", "leadSourceValue": "Other",
            "idTypePassportValue": "Passport", "idTypeIdCardValue": "National/Personal ID card",
        ],
        "programMember": [     // object: CampaignMember
            "attendanceStatus": "Attendance_Status__c", "attendingValue": "Attending",
            "status": "Status", "newMemberStatusValue": "Responded",
        ],
        "program": [           // object: Campaign (labelled "Program")
            "type": "Type", "studyTourTypeValue": "Study Tour",
            "city": "Study_Tour_City__c", "driveFolder": "Drive_Folder__c",
            "agendaDocument": "Agenda_Document__c", "knowledgeBase": "Knowledge_Base__c",
        ],
        "task": [              // object: Task (checklist items)
            "phase": "Study_Tour_Phase__c",
            "phaseValues": ["0 Setup", "1 Host Outreach", "2 Program and Promotion", "3 Registration",
                            "4 Submissions and Logistics", "5 Tour Days", "6 Wrap-up"],
            "openValue": "Open", "completedValue": "Completed", "priorityValue": "Normal", "emailSubtypeValue": "Email",
        ],
        "hostVisit": [         // object: Opportunity (one per host organisation and tour)
            "visitStart": "Visit_Start__c", "visitEnd": "Visit_End__c", "listDeadline": "List_Deadline__c",
            "location": "Visit_Location__c",   // meeting address if it differs from the organization's address
            "recipient": "Attendee_List_Recipient__c", "recipientRelationship": "Attendee_List_Recipient__r",
            "stageIdentified": "Qualification", "stageLetterSent": "Needs Analysis",
            "stagesInDiscussion": ["Proposal", "Negotiation"],
            "stageConfirmed": "Closed Won", "stageDeclined": "Closed Lost",
        ],
        "contact": [           // object: Contact (officials and assistants)
            "greeting": "Greeting__c",
            "vip": "VIP__c",           // checkbox: official role or the person visited (not assistants)
        ],
    ]

    /// Effective mapping (defaults + override file), flattened to "group.key".
    nonisolated(unsafe) public private(set) static var values: [String: Any] = load()

    public static subscript(_ key: String) -> String {
        if let s = values[key] as? String { return s }
        if let a = values[key] as? [String] { return a.joined(separator: "|") }
        assertionFailure("Unknown Salesforce mapping key \(key)")
        return ""
    }

    public static func list(_ key: String) -> [String] {
        (values[key] as? [String]) ?? (values[key] as? String).map { [$0] } ?? []
    }

    // MARK: Loading

    public static var overridePaths: [URL] {
        var p = [Store.directory.appendingPathComponent("salesforce-mapping.json")]
        if let r = Bundle.main.resourceURL { p.append(r.appendingPathComponent("salesforce-mapping.json")) }
        p.append(sourceConfigDir.appendingPathComponent("salesforce-mapping.json"))
        return p
    }

    static var sourceConfigDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config")
    }

    public static var overrideFile: URL? { overridePaths.first { FileManager.default.fileExists(atPath: $0.path) } }

    static func flatten(_ groups: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (g, v) in groups where !g.hasPrefix("_") {
            guard let dict = v as? [String: Any] else { continue }
            for (k, val) in dict where !k.hasPrefix("_") { out["\(g).\(k)"] = val }
        }
        return out
    }

    public static func load(override url: URL? = overrideFile) -> [String: Any] {
        var merged = flatten(defaults)
        if let url, let d = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in flatten(json) where merged[k] != nil { merged[k] = v }   // unknown keys are ignored
        }
        return merged
    }

    /// For tests / previews.
    public static func reload(override url: URL?) { values = load(override: url) }

    /// The defaults as JSON (written to config/salesforce-mapping.default.json).
    public static func defaultsJSON() throws -> Data {
        var doc: [String: Any] = defaults
        doc["_comment"] = "Copy to salesforce-mapping.json and change only what differs in your org. Keys starting with _ are ignored."
        return try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Schema check

    /// Custom fields the app relies on ("Object.Field"), derived from the mapping.
    public static var customFields: [(object: String, field: String)] {
        let objects = ["member": "Lead", "programMember": "CampaignMember", "program": "Campaign",
                       "task": "Task", "hostVisit": "Opportunity", "contact": "Contact"]
        return values.compactMap { key, v -> (String, String)? in
            guard let s = v as? String, s.hasSuffix("__c"), let g = key.split(separator: ".").first,
                  let obj = objects[String(g)] else { return nil }
            return (obj, s)
        }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    }
}
