import Foundation

public struct SFRecordRef: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case lead = "Lead", contact = "Contact", account = "Account", user = "User" }
    public let kind: Kind
    public let id: String
    public let name: String
    public let email: String
    public let accountId: String?
    public let accountName: String?

    public init(kind: Kind, id: String, name: String, email: String, accountId: String?, accountName: String?) {
        self.kind = kind; self.id = id; self.name = name; self.email = email
        self.accountId = accountId; self.accountName = accountName
    }
}

public struct SFUpdateResult: Sendable {
    public let id: String
    public let success: Bool
    public let message: String
}

/// Field names / picklist values from the Salesforce mapping.
enum F {
    static var city: String { SFMap["program.city"] }
    static var folder: String { SFMap["program.driveFolder"] }
    static var agenda: String { SFMap["program.agendaDocument"] }
    static var kb: String { SFMap["program.knowledgeBase"] }
    static var programType: String { SFMap["program.type"] }
    static var studyTourType: String { SFMap["program.studyTourTypeValue"] }
    static var phase: String { SFMap["task.phase"] }
    static var open: String { SFMap["task.openValue"] }
    static var completed: String { SFMap["task.completedValue"] }
    static var priority: String { SFMap["task.priorityValue"] }
    static var emailSubtype: String { SFMap["task.emailSubtypeValue"] }
    static var attendance: String { SFMap["programMember.attendanceStatus"] }
    static var attending: String { SFMap["programMember.attendingValue"] }
    static var memberStatus: String { SFMap["programMember.status"] }
    static var newMemberStatus: String { SFMap["programMember.newMemberStatusValue"] }
    static var visitStart: String { SFMap["hostVisit.visitStart"] }
    static var visitEnd: String { SFMap["hostVisit.visitEnd"] }
    static var deadline: String { SFMap["hostVisit.listDeadline"] }
    static var recipient: String { SFMap["hostVisit.recipient"] }
    static var recipientRel: String { SFMap["hostVisit.recipientRelationship"] }
    static var greeting: String { SFMap["contact.greeting"] }
}

/// Salesforce REST client: OAuth 2.0 web-server flow with PKCE and loopback redirect.
public final class SalesforceClient: @unchecked Sendable {
    public var settings: SalesforceSettings
    private var accessToken: String?

    public init(settings: SalesforceSettings) { self.settings = settings }

    public var isConnected: Bool { Keychain.get(Keychain.Key.sfRefresh) != nil }
    public var instanceURL: String { Keychain.get(Keychain.Key.sfInstance) ?? "" }
    private var redirectURI: String { "http://localhost:\(settings.callbackPort)/callback" }
    private var base: String { "\(instanceURL)/services/data/\(settings.apiVersion)" }

    // MARK: Auth

    public func connect(openURL: @escaping (URL) -> Void) async throws {
        guard !settings.effectiveClientId.isEmpty else { throw AppError("Enter the Salesforce Consumer Key in Settings first.") }
        let pkce = PKCE()
        var c = URLComponents(string: settings.loginURL + "/services/oauth2/authorize")!
        c.queryItems = [.init(name: "response_type", value: "code"),
                        .init(name: "client_id", value: settings.effectiveClientId),
                        .init(name: "redirect_uri", value: redirectURI),
                        .init(name: "code_challenge", value: pkce.challenge),
                        .init(name: "code_challenge_method", value: "S256"),
                        .init(name: "scope", value: "api refresh_token")]
        let url = c.url!
        let q = try await LoopbackReceiver(port: settings.callbackPort).waitForCode { openURL(url) }
        guard let code = q["code"] else { throw AppError("No authorization code received") }
        try await token(["grant_type": "authorization_code", "code": code, "client_id": settings.effectiveClientId,
                         "redirect_uri": redirectURI, "code_verifier": pkce.verifier])
    }

    public func disconnect() {
        accessToken = nil
        Keychain.set(nil, for: Keychain.Key.sfRefresh)
        Keychain.set(nil, for: Keychain.Key.sfInstance)
    }

    private func refresh() async throws {
        guard let rt = Keychain.get(Keychain.Key.sfRefresh) else { throw AppError("Salesforce is not connected.") }
        try await token(["grant_type": "refresh_token", "refresh_token": rt, "client_id": settings.effectiveClientId])
    }

    private func token(_ params: [String: String]) async throws {
        var req = URLRequest(url: URL(string: settings.loginURL + "/services/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = HTTP.formBody(params)
        let obj = try HTTP.json(try await HTTP.send(req, service: "Salesforce auth")) as? [String: Any] ?? [:]
        accessToken = obj["access_token"] as? String
        if let rt = obj["refresh_token"] as? String { Keychain.set(rt, for: Keychain.Key.sfRefresh) }
        if let inst = obj["instance_url"] as? String { Keychain.set(inst, for: Keychain.Key.sfInstance) }
    }

    // MARK: Core request

    @discardableResult
    public func call(_ method: String, _ path: String, body: Any? = nil, retry: Bool = true) async throws -> Any {
        if accessToken == nil { try await refresh() }
        let urlString = path.hasPrefix("/services") ? instanceURL + path : base + path
        guard let url = URL(string: urlString) else { throw AppError("Bad URL \(urlString)") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(accessToken ?? "")", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            return try HTTP.json(try await HTTP.send(req, service: "Salesforce"))
        } catch let e as APIError where e.status == 401 && retry {
            try await refresh()
            return try await call(method, path, body: body, retry: false)
        }
    }

    public func query(_ soql: String) async throws -> [[String: Any]] {
        var c = URLComponents()
        c.queryItems = [.init(name: "q", value: soql)]
        var path = "/query?" + (c.percentEncodedQuery ?? "")
        var rows: [[String: Any]] = []
        while true {
            let obj = try await call("GET", path) as? [String: Any] ?? [:]
            rows += obj["records"] as? [[String: Any]] ?? []
            guard let next = obj["nextRecordsUrl"] as? String else { break }
            path = next
        }
        return rows
    }

    /// `SELECT COUNT() …` → totalSize.
    public func count(_ soql: String) async throws -> Int {
        var c = URLComponents()
        c.queryItems = [.init(name: "q", value: soql)]
        let obj = try await call("GET", "/query?" + (c.percentEncodedQuery ?? "")) as? [String: Any] ?? [:]
        return obj["totalSize"] as? Int ?? 0
    }

    public func memberCount(campaignId: String) async throws -> Int {
        try await count("SELECT COUNT() FROM CampaignMember WHERE CampaignId = '\(Self.esc(campaignId))' AND LeadId != null")
    }

    public static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    private static func likeEsc(_ s: String) -> String {
        esc(s).replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    public func recordURL(_ id: String) -> URL? { URL(string: "\(instanceURL)/\(id)") }

    // MARK: Campaigns & Leads

    public func campaigns() async throws -> [(id: String, name: String)] {
        let filter = settings.topLevelProgramsOnly ? " AND ParentId = null" : ""
        return try await query("SELECT Id, Name FROM Campaign WHERE IsActive = true\(filter) ORDER BY StartDate DESC NULLS LAST, CreatedDate DESC LIMIT 200")
            .map { ($0["Id"] as? String ?? "", $0["Name"] as? String ?? "") }
    }

    // MARK: Tour storage on the program (Campaign)

    public struct ProgramRecord: Sendable {
        public var id: String
        public var name: String
        public var startDate: Date?
        public var endDate: Date?
        public var city: String?
        public var folder: String?
        public var agenda: String?
    }

    /// Custom schema the app relies on — derived from the Salesforce mapping.
    public static var requiredSchema: [(object: String, field: String)] { SFMap.customFields }

    private var describeCache: [String: Set<String>] = [:]

    public func fieldNames(of object: String) async throws -> Set<String> {
        if let c = describeCache[object] { return c }
        let d = try await call("GET", "/sobjects/\(object)/describe") as? [String: Any] ?? [:]
        let names = Set((d["fields"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        describeCache[object] = names
        return names
    }

    /// "Object.Field" entries of the metadata package that are not deployed (or not visible to this user).
    public func missingSchema() async throws -> [String] {
        describeCache = [:]
        var missing: [String] = []
        for (obj, field) in Self.requiredSchema where !(try await fieldNames(of: obj)).contains(field) {
            missing.append("\(obj).\(field)")
        }
        return missing
    }

    public func loadProgram(_ id: String) async throws -> ProgramRecord {
        let available = try await fieldNames(of: "Campaign")
        let optional = [F.city, F.folder, F.agenda].filter(available.contains)
        let rows = try await query("SELECT \((["Id", "Name", "StartDate", "EndDate"] + optional).joined(separator: ", ")) FROM Campaign WHERE Id = '\(Self.esc(id))' LIMIT 1")
        guard let r = rows.first else { throw AppError("Program \(id) not found in Salesforce") }
        func v(_ k: String) -> String? { (r[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return ProgramRecord(id: id, name: r["Name"] as? String ?? "",
                             startDate: v("StartDate").flatMap(Self.dayFormatter.date(from:)),
                             endDate: v("EndDate").flatMap(Self.dayFormatter.date(from:)),
                             city: available.contains(F.city) ? (r[F.city] as? String ?? "") : nil,
                             folder: v(F.folder), agenda: v(F.agenda))
    }

    /// Name, dates and city of the program.
    public func saveProgramBasics(_ id: String, name: String, start: Date, end: Date, city: String) async throws {
        var f: [String: Any] = ["Name": String(name.prefix(80)), "StartDate": Self.dayFormatter.string(from: start),
                                "EndDate": Self.dayFormatter.string(from: end)]
        if (try await fieldNames(of: "Campaign")).contains(F.city) { f[F.city] = String(city.prefix(80)) }
        try await call("PATCH", "/sobjects/Campaign/\(id)", body: f)
    }

    // MARK: Checklist (Tasks on the program with the phase field)

    public func checklist(programId: String) async throws -> [TaskItem] {
        guard (try await fieldNames(of: "Task")).contains(F.phase) else { return [] }
        let rows = try await query("""
            SELECT Id, Subject, ActivityDate, Status, OwnerId, Owner.Name, Description, \(F.phase) \
            FROM Task WHERE WhatId = '\(Self.esc(programId))' AND \(F.phase) != null ORDER BY ActivityDate, Subject
            """)
        return rows.compactMap { r in
            guard let phase = (r[F.phase] as? String).flatMap(PhaseID.init(salesforceValue:)) else { return nil }
            var t = TaskItem(phase: phase, title: r["Subject"] as? String ?? "", role: "", offsetDays: 0)
            t.salesforceId = r["Id"] as? String
            t.done = (r["Status"] as? String) == F.completed
            t.ownerId = r["OwnerId"] as? String
            t.ownerName = (r["Owner"] as? [String: Any])?["Name"] as? String
            t.dueDate = (r["ActivityDate"] as? String).flatMap(Self.dayFormatter.date(from:))
            t.notes = r["Description"] as? String ?? ""
            return t
        }
    }

    public static func taskFields(_ t: TaskItem, due: Date, programId: String?) -> [String: Any] {
        var f: [String: Any] = ["Subject": String(t.title.prefix(255)), "ActivityDate": dayFormatter.string(from: due),
                                "Status": t.done ? F.completed : F.open, "Priority": F.priority,
                                F.phase: t.phase.salesforceValue, "Description": t.notes]
        if let programId { f["WhatId"] = programId }
        if let o = t.ownerId { f["OwnerId"] = o }
        return f
    }

    public func createChecklistTask(_ t: TaskItem, due: Date, programId: String) async throws -> String {
        try await create("Task", Self.taskFields(t, due: due, programId: programId))
    }

    public func updateTask(_ id: String, fields: [String: Any]) async throws {
        try await call("PATCH", "/sobjects/Task/\(id)", body: fields)
    }

    public func deleteTask(_ id: String) async throws {
        do { try await call("DELETE", "/sobjects/Task/\(id)") } catch let e as APIError where e.status == 404 {}
    }

    // MARK: Users

    public func activeUsers() async throws -> [(id: String, name: String)] {
        try await query("SELECT Id, Name FROM User WHERE IsActive = true AND UserType = 'Standard' ORDER BY Name LIMIT 500")
            .map { ($0["Id"] as? String ?? "", $0["Name"] as? String ?? "") }
    }

    public func currentUserId() async throws -> String? {
        (try await call("GET", "/services/oauth2/userinfo") as? [String: Any])?["user_id"] as? String
    }

    public func createProgram(name: String, start: Date, end: Date, city: String = "") async throws -> String {
        var f: [String: Any] = ["Name": String(name.prefix(80)), "IsActive": true, F.programType: F.studyTourType,
                                "StartDate": Self.dayFormatter.string(from: start), "EndDate": Self.dayFormatter.string(from: end),
                                KnowledgeBase.programField: KnowledgeBase.defaultURL]
        let available = try await fieldNames(of: "Campaign")
        if !available.contains(KnowledgeBase.programField) { f[KnowledgeBase.programField] = nil }   // not deployed yet
        if available.contains(F.city), !city.isEmpty { f[F.city] = String(city.prefix(80)) }
        return try await create("Campaign", f)
    }

    /// The program's knowledge base document URL (nil if the field is empty or not deployed yet).
    public func knowledgeBaseURL(programId: String) async throws -> String? {
        do {
            let rows = try await query("SELECT \(KnowledgeBase.programField) FROM Campaign WHERE Id = '\(Self.esc(programId))' LIMIT 1")
            let v = rows.first?[KnowledgeBase.programField] as? String
            return (v?.isEmpty ?? true) ? nil : v
        } catch let e as APIError where e.body.contains("INVALID_FIELD") || e.body.contains("No such column") {
            return nil
        }
    }

    /// Drive folder and agenda links of a program (nil = not set / fields not deployed).
    public func programLinks(programId: String) async throws -> (folder: String?, agenda: String?) {
        do {
            let r = try await query("SELECT \(F.folder), \(F.agenda) FROM Campaign WHERE Id = '\(Self.esc(programId))' LIMIT 1").first ?? [:]
            func v(_ k: String) -> String? { (r[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            return (v(F.folder), v(F.agenda))
        } catch let e as APIError where e.body.contains("INVALID_FIELD") || e.body.contains("No such column") {
            return (nil, nil)
        }
    }

    public func setProgramLinks(programId: String, folder: String, agenda: String?) async throws {
        var f: [String: Any] = [F.folder: folder]
        if let agenda { f[F.agenda] = agenda }
        try await call("PATCH", "/sobjects/Campaign/\(programId)", body: f)
    }

    public func setKnowledgeBaseURL(programId: String, url: String) async throws {
        try await call("PATCH", "/sobjects/Campaign/\(programId)", body: [KnowledgeBase.programField: url])
    }

    /// Salesforce Date fields are calendar days: format/parse in the user's time zone (local midnight),
    /// matching what the date pickers produce — avoids off-by-one days around UTC.
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Child programs (campaigns) of the tour's main program.
    public func childCampaigns(parentId: String) async throws -> [(id: String, name: String)] {
        try await query("SELECT Id, Name FROM Campaign WHERE ParentId = '\(Self.esc(parentId))' ORDER BY CreatedDate")
            .map { ($0["Id"] as? String ?? "", $0["Name"] as? String ?? "") }
    }

    /// Creates an additional program (Campaign) under the tour's main program.
    public func createCampaign(name: String, parentId: String?) async throws -> String {
        var f: [String: Any] = ["Name": String(name.prefix(80)), "IsActive": true]
        if let parentId, !parentId.isEmpty { f["ParentId"] = parentId }
        return try await create("Campaign", f)
    }

    public func addContactToCampaign(contactId: String, campaignId: String) async throws {
        do { _ = try await create("CampaignMember", ["ContactId": contactId, "CampaignId": campaignId]) }
        catch let e as APIError where e.body.contains("DUPLICATE_VALUE") || e.body.contains("already") {}
    }

    private var leadFieldCache: Set<String>?

    /// Lead fields that exist in the org (new fields may not be deployed yet).
    public func leadFieldNames() async throws -> Set<String> {
        if let c = leadFieldCache { return c }
        let d = try await call("GET", "/sobjects/Lead/describe") as? [String: Any] ?? [:]
        let names = Set((d["fields"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        leadFieldCache = names
        return names
    }

    public func leads(campaignId: String) async throws -> [Participant] {
        let available = try await fieldNames(of: "Lead")
        let mapped = ParticipantField.allCases.filter { available.contains(settings.field($0)) }
        let select = (["Id"] + mapped.map { settings.field($0) }).joined(separator: ", ")
        var whereClause = "IsConverted = false"
        if !campaignId.isEmpty {
            // Participants = program members with Attendance Status "Attending" (Invited/Applied/Cancelled excluded)
            whereClause += " AND Id IN (SELECT LeadId FROM CampaignMember WHERE CampaignId = '\(Self.esc(campaignId))' AND \(F.attendance) = '\(F.attending)')"
        }
        if !settings.leadFilter.trimmingCharacters(in: .whitespaces).isEmpty {
            whereClause += " AND (\(settings.leadFilter))"
        }
        guard !campaignId.isEmpty || !settings.leadFilter.isEmpty else {
            throw AppError("Link the tour program in the Setup phase, or set a member (Lead) filter in Settings.")
        }
        let rows = try await query("SELECT \(select) FROM Lead WHERE \(whereClause) ORDER BY LastName")
        return rows.map { row in
            var v: [ParticipantField: String] = [:]
            for f in ParticipantField.allCases {
                if let s = row[settings.field(f)] as? String { v[f] = s }
                else if let n = row[settings.field(f)] as? NSNumber { v[f] = n.stringValue }
            }
            return Participant(id: row["Id"] as? String ?? "", values: v)
        }
    }

    /// Updates Lead fields. A `nil` value clears the field. Batches of 200 (composite API limit).
    public func updateLeads(_ updates: [String: [ParticipantField: String?]]) async throws -> [SFUpdateResult] {
        var results: [SFUpdateResult] = []
        let items = Array(updates)
        for chunkStart in stride(from: 0, to: items.count, by: 200) {
            let chunk = items[chunkStart..<min(chunkStart + 200, items.count)]
            let records: [[String: Any]] = chunk.map { id, fields in
                var r: [String: Any] = ["attributes": ["type": "Lead"], "id": id]
                for (f, v) in fields { r[settings.field(f)] = v.map { $0 as Any } ?? NSNull() }
                return r
            }
            let resp = try await call("PATCH", "/composite/sobjects", body: ["allOrNone": false, "records": records]) as? [[String: Any]] ?? []
            for (i, r) in resp.enumerated() {
                let errs = (r["errors"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }.joined(separator: "; ")
                results.append(SFUpdateResult(id: r["id"] as? String ?? chunk[chunk.startIndex + i].key,
                                              success: r["success"] as? Bool ?? false, message: errs))
            }
        }
        return results
    }

    // MARK: Permissions & org-wide scrub

    /// True if the signed-in user has "Modify All Data" (via profile or permission set).
    public func hasModifyAllData() async throws -> Bool {
        let info = try await call("GET", "/services/oauth2/userinfo") as? [String: Any] ?? [:]
        guard let uid = info["user_id"] as? String else { return false }
        let n = try await count("SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = '\(Self.esc(uid))' AND PermissionSet.PermissionsModifyAllData = true")
        return n > 0
    }

    private func anyFilled(_ fields: [ParticipantField]) -> String {
        "(" + fields.map { "\(settings.field($0)) != null" }.joined(separator: " OR ") + ")"
    }

    public func leadIdsWithData(in fields: [ParticipantField]) async throws -> [String] {
        guard !fields.isEmpty else { return [] }
        return try await query("SELECT Id FROM Lead WHERE IsConverted = false AND \(anyFilled(fields))").compactMap { $0["Id"] as? String }
    }

    public func convertedLeadCountWithData(in fields: [ParticipantField]) async throws -> Int {
        guard !fields.isEmpty else { return 0 }
        return try await count("SELECT COUNT() FROM Lead WHERE IsConverted = true AND \(anyFilled(fields))")
    }

    // MARK: Host visits (Opportunities on the program)

    public func hostVisits(programId: String) async throws -> [HostVisit] {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        func dt(_ v: Any?) -> Date? { (v as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) } }
        let rows = try await query("""
            SELECT Id, Name, StageName, AccountId, Account.Name, \(F.visitStart), \(F.visitEnd), \(F.deadline), \
            \(F.recipient), \(F.recipientRel).Name, \(F.recipientRel).Email, \
            \(F.recipientRel).\(F.greeting) FROM Opportunity WHERE CampaignId = '\(Self.esc(programId))' \
            ORDER BY \(F.visitStart) NULLS LAST, Name
            """)
        return rows.map { r in
            let rec = r[F.recipientRel] as? [String: Any]
            return HostVisit(id: r["Id"] as? String ?? "", name: r["Name"] as? String ?? "", stage: r["StageName"] as? String ?? "",
                             accountId: r["AccountId"] as? String, organization: (r["Account"] as? [String: Any])?["Name"] as? String ?? "",
                             visitStart: dt(r[F.visitStart]), visitEnd: dt(r[F.visitEnd]),
                             listDeadline: (r[F.deadline] as? String).flatMap(Self.dayFormatter.date(from:)),
                             recipientId: r[F.recipient] as? String,
                             recipientName: rec?["Name"] as? String ?? "", recipientEmail: rec?["Email"] as? String ?? "",
                             recipientGreeting: rec?[F.greeting] as? String ?? "")
        }
    }

    /// Excel files attached to a record (newest first) — the host's attendee-list template.
    public func spreadsheets(on recordId: String) async throws -> [SalesforceFile] {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try await query("""
            SELECT ContentDocument.LatestPublishedVersionId, ContentDocument.Title, ContentDocument.FileExtension, \
            ContentDocument.ContentModifiedDate FROM ContentDocumentLink WHERE LinkedEntityId = '\(Self.esc(recipientSafe(recordId)))'
            """).compactMap { r in
            guard let d = r["ContentDocument"] as? [String: Any], let ext = (d["FileExtension"] as? String)?.lowercased(),
                  ["xlsx", "xlsm"].contains(ext), let vid = d["LatestPublishedVersionId"] as? String else { return nil }
            return SalesforceFile(id: vid, title: d["Title"] as? String ?? "Attachment", fileExtension: ext,
                                  modified: (d["ContentModifiedDate"] as? String).flatMap(iso.date(from:)))
        }.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    private func recipientSafe(_ id: String) -> String { id.filter { $0.isLetter || $0.isNumber } }

    /// Binary content of a file version.
    public func download(versionId: String, retry: Bool = true) async throws -> Data {
        if accessToken == nil { try await refresh() }
        var req = URLRequest(url: URL(string: "\(base)/sobjects/ContentVersion/\(versionId)/VersionData")!)
        req.setValue("Bearer \(accessToken ?? "")", forHTTPHeaderField: "Authorization")
        do { return try await HTTP.send(req, service: "Salesforce file") }
        catch let e as APIError where e.status == 401 && retry {
            try await refresh()
            return try await download(versionId: versionId, retry: false)
        }
    }

    // MARK: Accounts & Contacts (hosts)

    public func searchAccounts(_ text: String) async throws -> [(id: String, name: String, website: String)] {
        let t = Self.likeEsc(text)
        return try await query("SELECT Id, Name, Website FROM Account WHERE Name LIKE '%\(t)%' ORDER BY Name LIMIT 50")
            .map { ($0["Id"] as? String ?? "", $0["Name"] as? String ?? "", $0["Website"] as? String ?? "") }
    }

    public func contacts(accountId: String) async throws -> [HostContact] {
        try await query("SELECT Id, Name, Email, Title FROM Contact WHERE AccountId = '\(Self.esc(accountId))' ORDER BY LastName")
            .map { HostContact(id: $0["Id"] as? String ?? "", name: $0["Name"] as? String ?? "",
                               email: $0["Email"] as? String ?? "", title: $0["Title"] as? String ?? "") }
    }

    // MARK: Duplicate-safe lookups

    /// Finds existing Leads/Contacts with this email address.
    public func findPeople(email: String) async throws -> [SFRecordRef] {
        let e = Self.esc(email.lowercased())
        let leads = try await query("SELECT Id, Name, Email, Company FROM Lead WHERE Email = '\(e)' AND IsConverted = false LIMIT 10")
        let contacts = try await query("SELECT Id, Name, Email, AccountId, Account.Name FROM Contact WHERE Email = '\(e)' LIMIT 10")
        return contacts.map(Self.contactRef) + leads.map(Self.leadRef)
    }

    /// Active Salesforce users with this email (organisers — never treated as attendees or officials).
    public func findUsers(email: String) async throws -> [SFRecordRef] {
        try await query("SELECT Id, Name, Email FROM User WHERE Email = '\(Self.esc(email.lowercased()))' AND IsActive = true LIMIT 5")
            .map { SFRecordRef(kind: .user, id: $0["Id"] as? String ?? "", name: $0["Name"] as? String ?? "",
                               email: $0["Email"] as? String ?? "", accountId: nil, accountName: nil) }
    }

    /// Finds Leads/Contacts with the same first and last name (used when the email differs).
    public func findPeople(firstName: String, lastName: String) async throws -> [SFRecordRef] {
        guard !lastName.isEmpty else { return [] }
        let f = Self.esc(firstName), l = Self.esc(lastName)
        let leads = try await query("SELECT Id, Name, Email, Company FROM Lead WHERE FirstName = '\(f)' AND LastName = '\(l)' AND IsConverted = false LIMIT 10")
        let contacts = try await query("SELECT Id, Name, Email, AccountId, Account.Name FROM Contact WHERE FirstName = '\(f)' AND LastName = '\(l)' LIMIT 10")
        return contacts.map(Self.contactRef) + leads.map(Self.leadRef)
    }

    public func findAccounts(name: String, domain: String?) async throws -> [SFRecordRef] {
        var conds: [String] = []
        if !name.isEmpty { conds.append("Name LIKE '%\(Self.likeEsc(name))%'") }
        if let d = domain, !d.isEmpty, !EmailRules.freemailDomains.contains(d) { conds.append("Website LIKE '%\(Self.likeEsc(d))%'") }
        guard !conds.isEmpty else { return [] }
        return try await query("SELECT Id, Name, Website FROM Account WHERE \(conds.joined(separator: " OR ")) LIMIT 10")
            .map { SFRecordRef(kind: .account, id: $0["Id"] as? String ?? "", name: $0["Name"] as? String ?? "",
                               email: "", accountId: $0["Id"] as? String, accountName: $0["Name"] as? String) }
    }

    private static func leadRef(_ r: [String: Any]) -> SFRecordRef {
        SFRecordRef(kind: .lead, id: r["Id"] as? String ?? "", name: r["Name"] as? String ?? "",
                    email: r["Email"] as? String ?? "", accountId: nil, accountName: r["Company"] as? String)
    }

    private static func contactRef(_ r: [String: Any]) -> SFRecordRef {
        SFRecordRef(kind: .contact, id: r["Id"] as? String ?? "", name: r["Name"] as? String ?? "",
                    email: r["Email"] as? String ?? "", accountId: r["AccountId"] as? String,
                    accountName: (r["Account"] as? [String: Any])?["Name"] as? String)
    }

    // MARK: Create

    public func create(_ type: String, _ fields: [String: Any]) async throws -> String {
        let r = try await call("POST", "/sobjects/\(type)", body: fields) as? [String: Any] ?? [:]
        guard let id = r["id"] as? String else { throw AppError("Salesforce did not return an id for new \(type)") }
        return id
    }

    public func addToCampaign(leadId: String, campaignId: String) async throws {
        guard !campaignId.isEmpty else { return }
        do {
            _ = try await create("CampaignMember", ["LeadId": leadId, "CampaignId": campaignId, F.memberStatus: F.newMemberStatus])
        } catch let e as APIError where e.body.contains("DUPLICATE_VALUE") || e.body.contains("already a campaign member") {
            // already a member — fine
        } catch let e as APIError where e.body.contains("Status") {
            _ = try await create("CampaignMember", ["LeadId": leadId, "CampaignId": campaignId])
        }
    }

    // MARK: Activities (emails are sent via Gmail and tracked here)

    /// Creates many completed Tasks at once (composite API, 200 per call). Returns the number created.
    @discardableResult
    public func createTasks(_ tasks: [[String: Any]]) async throws -> Int {
        var ok = 0
        for start in stride(from: 0, to: tasks.count, by: 200) {
            let records = tasks[start..<min(start + 200, tasks.count)].map { t -> [String: Any] in
                var r = t; r["attributes"] = ["type": "Task"]; return r
            }
            let resp = try await call("POST", "/composite/sobjects", body: ["allOrNone": false, "records": records]) as? [[String: Any]] ?? []
            ok += resp.filter { ($0["success"] as? Bool) == true }.count
        }
        return ok
    }

    /// Data-protection record on the member itself.
    public static func dataProtectionTask(leadId: String, fields: [ParticipantField], scope: String, date: Date = Date()) -> [String: Any] {
        ["WhoId": leadId,
         "Subject": "Data protection: passport data deleted",
         "Description": "Cleared fields: \(fields.map(\.label).joined(separator: ", ")).\nScope: \(scope).\nDeleted by the Fulbright Study Tours app.",
         "Status": F.completed, "Priority": F.priority, "ActivityDate": Dates.iso(date)]
    }

    public enum Direction: String, Sendable { case inbound = "Inbound", outbound = "Outbound" }

    /// Records an email as a completed Task (activity) on a Lead or Contact (+ Account).
    public func logEmailTask(whoId: String, whatId: String?, subject: String, body: String,
                             date: Date, direction: Direction, counterpart: String) async throws {
        var fields: [String: Any] = [
            "WhoId": whoId,
            "Subject": String("Email \(direction == .inbound ? "from" : "to") \(counterpart): \(subject)".prefix(255)),
            "Description": String(body.prefix(31000)),
            "Status": F.completed,
            "Priority": F.priority,
            "TaskSubtype": F.emailSubtype,
            "ActivityDate": Dates.iso(date),
        ]
        if let whatId, whoId.hasPrefix("003") { fields["WhatId"] = whatId }   // WhatId only allowed with Contacts
        _ = try await create("Task", fields)
    }

    // MARK: Calendar (Events)

    public func upsertEvent(_ item: AgendaItem, whatId: String?, tourName: String) async throws -> String {
        let iso = ISO8601DateFormatter()
        var fields: [String: Any] = [
            "Subject": String("\(tourName): \(item.title)".prefix(255)),
            "StartDateTime": iso.string(from: item.start),
            "EndDateTime": iso.string(from: item.end),
            "Location": String(item.location.prefix(255)),
            "Description": item.details,
        ]
        if let whatId { fields["WhatId"] = whatId }
        if let id = item.salesforceEventId {
            do {
                try await call("PATCH", "/sobjects/Event/\(id)", body: fields)
                return id
            } catch let e as APIError where e.status == 404 {
                // deleted in Salesforce → recreate
            }
        }
        return try await create("Event", fields)
    }

    public func deleteEvent(_ id: String) async throws {
        do { try await call("DELETE", "/sobjects/Event/\(id)") }
        catch let e as APIError where e.status == 404 {}
    }
}
