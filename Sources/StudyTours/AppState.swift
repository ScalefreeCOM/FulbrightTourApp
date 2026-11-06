import SwiftUI
import UniformTypeIdentifiers
import AppKit
import StudyToursCore

/// A prepared attendee list for one host visit (in memory only — contains passport data).
struct HostListDraft {
    var visit: HostVisit
    var file: SalesforceFile
    var template: XLSXTemplate
    var mapping: TemplateMapping
    var mappingSource: String
    var filled: Data?
    var localURL: URL?
    var participantCount = 0
    var missing: [String] = []
    var subject = ""
    var body = ""
    var sentAt: Date?

    func fileName(tour: String) -> String {
        let safe = { (s: String) in s.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" } }
        return "\(safe(tour)) – \(safe(visit.organization.isEmpty ? visit.name : visit.organization)) – attendees.xlsx"
    }
}

struct InboxItem: Identifiable, Hashable {
    var id: String { message.id }
    var message: MailMessage
    var identity: SenderIdentity
    var triage: MailTriage?
    var important: Bool
    var draft: DraftReply?
    var draftBody: String = ""
    var status: String = ""
    var answered: Bool = false
    var logged: Bool = false
    var proposal: RecordProposal?
    /// CC recipients of the reply; nil = not edited yet (defaults to "reply all").
    var replyCC: [String]?
}

enum SidebarItem: Hashable {
    case overview, phase(PhaseID), agenda, inbox, settings
}

struct SignInPrompt: Identifiable, Equatable {
    let service: String
    let url: URL
    let port: Int
    var id: String { url.absoluteString }
}

@MainActor
@Observable
final class AppState {
    var data: AppData
    var selection: SidebarItem? = .overview

    // live, in-memory only (never written to disk — contains passport data)
    var participants: [Participant] = []
    var report: CleansingReport?
    var selectedChanges: Set<String> = []

    var inbox: [InboxItem] = []
    var programsInOrg: [(id: String, name: String)] = []

    // monitoring
    var memberCount: Int?
    /// Attendees with at least one empty ID-document field (At a Glance).
    var incompletePassports: Int?
    var unreadCount: Int?
    var lastScan: Date?

    // central storage (Salesforce program) & team sync
    var syncStatus = "Local only"
    var showNewProgram = false
    var currentUserId: String?
    /// First name of the signed-in Salesforce user, used to sign drafts.
    var signOffName: String { Assistant.signOffName(userName: users.first { $0.id == currentUserId }?.name) }
    /// Full name of the signed-in Salesforce user, used when writing to officials.
    var signOffFullName: String { Assistant.signOffFullName(userName: users.first { $0.id == currentUserId }?.name) }

    /// Members get the first name; officials the full name (or the first name if the draft already used it).
    func ensureSignOff(_ body: String, to sender: SenderKind) -> String {
        sender == .official ? Assistant.ensureSignOff(body, name: signOffFullName, accept: [signOffName])
                            : Assistant.ensureSignOff(body, name: signOffName)
    }
    var users: [(id: String, name: String, email: String)] = []
    /// Address of the signed-in user's own mailbox (never CC'd on replies).
    var myMailAddress = ""
    var lastSavedBasics: [String: Basics] = [:]
    private var pendingProgramSave: Task<Void, Never>?
    var storageMissingFields: [String] = []
    var isSalesforceAdmin = false
    private var pullTask: Task<Void, Never>?
    /// Observable mirror of the login state. The clients read the Keychain, which SwiftUI cannot observe,
    /// so views use these and they are refreshed after every connect/disconnect.
    private(set) var salesforceConnected = false
    /// Signed in, but the last attempt to reach Salesforce failed (shown in the footer, offers "Reconnect").
    var salesforceProblem: String?
    private(set) var googleConnected = false
    private(set) var geminiConfigured = false
    /// The saved Gemini key is the sponsored one (footer: "Gemini AI is sponsored by Scalefree").
    private(set) var geminiSponsored = false
    /// Gemini tokens used on this Mac since the counter was introduced (kept across launches).
    private(set) var geminiTokensUsed: Int = UserDefaults.standard.integer(forKey: "geminiTokensUsed")

    // host visits (Opportunities) and attendee-list drafts
    var hostVisits: [HostVisit] = []
    var hostListDrafts: [String: HostListDraft] = [:]     // Opportunity Id → draft (contains passport data; memory only)

    var busy: String?
    var lastError: String?
    var toast: String?
    /// Sign-in waiting for the browser: shown as a sheet so the user can pick the browser/profile.
    var signIn: SignInPrompt?
    /// Inbox item whose "new record" proposal is open in the review pop-up.
    var reviewingProposal: String?
    /// Mail selected in the Inbox (also set from "At a Glance").
    var inboxSelection: String?

    let salesforce: SalesforceClient
    let google: GoogleClient
    let gemini: GeminiClient

    // knowledge base (Google Doc referenced by the program's knowledge base field)
    var knowledgeBaseURL = KnowledgeBase.defaultURL
    var knowledgeBaseStatus = "Not loaded"
    private var kbText = ""
    private var kbLoadedAt: Date?
    private var kbLoadedURL = ""

    private var triageCache: [String: MailTriage] = [:]
    private var senderCache: [String: [SFRecordRef]] = [:]
    private var pollTask: Task<Void, Never>?

    // team chat (Google Chat)
    var chatMessages: [ChatMessage] = []
    var chatDraft = ""
    var chatError: String?
    var chatSending = false
    private var chatTask: Task<Void, Never>?
    private var chatNames: [String: String] = [:]
    private(set) var myChatUserId = ""
    private var chatSpaceLoaded = ""

    init() {
        let d = Store.load()
        data = d
        salesforce = SalesforceClient(settings: d.settings.salesforce)
        google = GoogleClient(settings: d.settings.google)
        gemini = GeminiClient(settings: d.settings.gemini)
        gemini.onUsage = { [weak self] tokens in
            Task { @MainActor in
                guard let self else { return }
                self.geminiTokensUsed += tokens
                UserDefaults.standard.set(self.geminiTokensUsed, forKey: "geminiTokensUsed")
            }
        }
        gemini.onModelChanged = { [weak self] model in
            Task { @MainActor in
                self?.settings.gemini.model = model
                self?.flash("Gemini model updated to \(model) (the previous one was retired by Google)")
            }
        }
        if data.tours.isEmpty { newLocalTour() }
        refreshConnectionState()
        startPolling()
        startPulling()
        startChatPolling()
    }

    // MARK: Tour access

    var tourIndex: Int {
        data.tours.firstIndex { $0.id == data.selectedTourId } ?? 0
    }

    var tour: Tour {
        get { data.tours[tourIndex] }
        set { data.tours[tourIndex] = newValue; save() }
    }

    /// Display title: always the Salesforce program name (contains city and year).
    var tourTitle: String { tour.campaignId.isEmpty ? "No program selected" : tour.name }

    var isCentral: Bool { !tour.campaignId.isEmpty && salesforceConnected && storageMissingFields.isEmpty == true }

    var settings: AppSettings {
        get { data.settings }
        set {
            data.settings = newValue
            salesforce.settings = newValue.salesforce
            google.settings = newValue.google
            gemini.settings = newValue.gemini
            save()
        }
    }

    /// Offline tour used until a Salesforce program is selected.
    func newLocalTour() {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: 120, to: cal.startOfDay(for: Date()))!
        let t = Tour(name: "Study Tour \(cal.component(.year, from: start))", startDate: start,
                     endDate: cal.date(byAdding: .day, value: 3, to: start)!)
        data.tours.append(t)
        data.selectedTourId = t.id
        save()
    }

    /// Persists locally and (debounced) pushes the tour to its Salesforce program.
    func save() {
        do { try Store.save(data) } catch { lastError = "Could not save: \(error.localizedDescription)" }
        scheduleSync()
    }

    // MARK: Helpers

    func run(_ label: String, _ work: @escaping () async throws -> Void) {
        Task {
            busy = label
            lastError = nil
            defer { busy = nil }
            do { try await work() } catch { lastError = error.localizedDescription }
            refreshConnectionState()   // a failed token refresh signs the client out
        }
    }

    func flash(_ s: String) {
        toast = s
        Task { try? await Task.sleep(for: .seconds(4)); if toast == s { toast = nil } }
    }

    nonisolated static func open(_ url: URL) { NSWorkspace.shared.open(url) }

    var requiredFields: Set<ParticipantField> {
        Set(tour.hosts.filter { $0.status != .declined }.flatMap(\.requiredFields))
    }


    // MARK: Connections

    func connectSalesforce() {
        let port = settings.salesforce.callbackPort
        run("Connecting to Salesforce…") {
            defer { self.signIn = nil }
            try await self.salesforce.connect(openURL: self.showSignIn("Salesforce", port: port))
            self.refreshConnectionState()
            self.flash("Salesforce connected")
            try await self.salesforceStartup()
        }
    }

    /// Programs, schema check, admin check, users — on connect and at app start.
    func salesforceStartup() async throws {
        programsInOrg = try await salesforce.campaigns()
        storageMissingFields = (try? await salesforce.missingSchema()) ?? []
        isSalesforceAdmin = (try? await salesforce.hasModifyAllData()) ?? false
        currentUserId = try? await salesforce.currentUserId()
        users = (try? await salesforce.activeUsers()) ?? []
        if !tour.campaignId.isEmpty { await refreshProgram() }
    }
    func connectGoogle() {
        let port = settings.google.callbackPort
        run("Connecting to Google…") {
            defer { self.signIn = nil }
            try await self.google.connect(openURL: self.showSignIn("Google", port: port))
            self.refreshConnectionState()
            self.flash("Google connected")
        }
    }

    /// Instead of opening the default browser right away, show the link so the user can choose
    /// the browser or profile that is signed in with the right account.
    private func showSignIn(_ service: String, port: Int) -> (URL) -> Void {
        { url in Task { @MainActor in self.signIn = SignInPrompt(service: service, url: url, port: port) } }
    }

    func cancelSignIn() {
        if let p = signIn { LoopbackReceiver.cancel(port: p.port) }
        signIn = nil
    }

    func disconnectSalesforce() { salesforce.disconnect(); refreshConnectionState() }
    func disconnectGoogle() { google.disconnect(); refreshConnectionState() }

    func refreshConnectionState() {
        salesforceConnected = salesforce.isConnected
        googleConnected = google.isConnected
        geminiConfigured = gemini.isConfigured
        geminiSponsored = AppConfig.geminiKeyIsSponsored
    }

    // MARK: Setup

    func loadPrograms() {
        run("Loading programs…") {
            do { self.programsInOrg = try await self.salesforce.campaigns(); self.salesforceProblem = nil }
            catch { self.salesforceProblem = error.localizedDescription; throw error }
        }
    }

    /// Starts a fresh Salesforce session with the saved login and reloads programs, fields and users.
    func reconnectSalesforce() {
        guard salesforce.isConnected else { selection = .settings; return }
        run("Reconnecting to Salesforce…") {
            self.salesforce.resetSession()
            do {
                try await self.salesforceStartup()
                self.salesforceProblem = nil
                self.lastError = nil
                await self.refreshProgram()
                self.flash("Salesforce reconnected")
            } catch {
                self.salesforceProblem = error.localizedDescription
                throw error
            }
            self.refreshConnectionState()
        }
    }

    // MARK: Tour = Salesforce program (native fields, Tasks, Opportunities)

    /// Switches to the study tour of this program.
    func selectProgram(id: String, name: String) {
        guard !id.isEmpty, id != tour.campaignId else { return }
        participants = []; report = nil; memberCount = nil; incompletePassports = nil; inbox = []; hostVisits = []; hostListDrafts = [:]
        if let cached = data.tours.first(where: { $0.campaignId == id }) {
            data.selectedTourId = cached.id
        } else {
            var t = Tour(name: name, startDate: Date(), endDate: Date())
            t.campaignId = id; t.campaignName = name; t.tasks = []
            data.tours.append(t)
            data.selectedTourId = t.id
        }
        try? Store.save(data)
        run("Loading study tour…") { await self.refreshProgram() }
    }

    /// Creates a new program in Salesforce (with folder, agenda and default checklist) and selects it.
    func createProgramTour(name: String, start: Date, end: Date, city: String) {
        run("Creating program…") {
            let id = try await self.salesforce.createProgram(name: name, start: start, end: end, city: city)
            var t = Tour(name: name, startDate: start, endDate: end)
            t.city = city; t.campaignId = id; t.campaignName = name; t.tasks = []
            self.data.tours.append(t)
            self.data.selectedTourId = t.id
            self.programsInOrg.insert((id: id, name: name), at: 0)
            self.participants = []; self.report = nil; self.memberCount = nil; self.incompletePassports = nil; self.inbox = []; self.hostVisits = []
            self.lastSavedBasics[id] = Basics(t)
            try await self.createDefaultChecklist()
            if self.google.isConnected { try await self.setUpDrive() }
            self.flash("Program “\(name)” created")
        }
    }

    /// Reloads everything the team shares: program fields, links, child programs, checklist, host visits.
    func refreshProgram() async {
        let cid = tour.campaignId
        guard !cid.isEmpty, salesforce.isConnected, pendingProgramSave == nil else { return }
        do {
            let r = try await salesforce.loadProgram(cid)
            var t = tour
            t.name = r.name; t.campaignName = r.name
            if let s = r.startDate { t.startDate = s }
            if let e = r.endDate { t.endDate = e }
            if let c = r.city { t.city = c }
            if let f = r.folder.flatMap(DriveStructure.id(from:)) { t.driveFolderId = f }
            if let a = r.agenda.flatMap(DriveStructure.id(from:)) { t.agendaDocId = a }
            for c in try await salesforce.childCampaigns(parentId: cid) where !t.programs.contains(where: { $0.id == c.id }) {
                t.programs.append(LinkedProgram(id: c.id, name: c.name, purpose: "Linked"))
            }
            if !storageMissingFields.contains("Task.\(SFMap["task.phase"])") {
                t.tasks = try await salesforce.checklist(programId: cid)
            }
            lastSavedBasics[cid] = Basics(t)
            if let i = data.tours.firstIndex(where: { $0.campaignId == cid }) { data.tours[i] = t }
            try? Store.save(data)
            hostVisits = (try? await salesforce.hostVisits(programId: cid)) ?? hostVisits
            syncStatus = "Up to date \(Date().formatted(date: .omitted, time: .shortened))"
            await refreshMetrics()
        } catch {
            syncStatus = "Offline — showing last known state"
        }
    }

    /// Name, dates, city as last read from / written to Salesforce (to detect local edits).
    struct Basics: Equatable {
        let name: String, start: Date, end: Date, city: String
        init(_ t: Tour) { name = t.name; start = t.startDate; end = t.endDate; city = t.city }
    }

    /// Debounced save of name / dates / city to the program fields.
    func scheduleSync() {
        let cid = tour.campaignId
        guard !cid.isEmpty, salesforce.isConnected, Basics(tour) != lastSavedBasics[cid] else { return }
        pendingProgramSave?.cancel()
        pendingProgramSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            defer { self.pendingProgramSave = nil }
            let t = self.tour
            guard t.campaignId == cid else { return }
            do {
                try await self.salesforce.saveProgramBasics(cid, name: t.name, start: t.startDate, end: t.endDate, city: t.city)
                self.lastSavedBasics[cid] = Basics(t)
                if let i = self.programsInOrg.firstIndex(where: { $0.id == cid }) { self.programsInOrg[i].name = t.name }
                self.syncStatus = "Saved \(Date().formatted(date: .omitted, time: .shortened))"
            } catch {
                self.syncStatus = "Save failed"; self.lastError = error.localizedDescription
            }
        }
    }

    func startPulling() {
        pullTask?.cancel()
        pullTask = Task { [weak self] in
            if let self, self.salesforce.isConnected {
                do { try await self.salesforceStartup(); self.salesforceProblem = nil }
                catch { self.salesforceProblem = error.localizedDescription }
            }
            self?.refreshConnectionState()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.refreshProgram()
                self?.refreshConnectionState()
            }
        }
    }

    // MARK: Checklist (Salesforce Tasks)

    var checklistInSalesforce: Bool {
        !tour.campaignId.isEmpty && salesforceConnected && !storageMissingFields.contains("Task.\(SFMap["task.phase"])")
    }

    /// Default plan → Tasks on the program, due dates from the tour dates, owned by the current user.
    func createDefaultChecklist() async throws {
        guard checklistInSalesforce else { tour.tasks = PhasePlan.defaultTasks(); return }
        let t = tour
        for var item in PhasePlan.defaultTasks() {
            item.ownerId = currentUserId
            _ = try await salesforce.createChecklistTask(item, due: t.dueDate(item), programId: t.campaignId)
        }
        tour.tasks = try await salesforce.checklist(programId: t.campaignId)
    }

    func createDefaultChecklistAction() { run("Creating checklist…") { try await self.createDefaultChecklist() } }

    /// Updates a checklist item locally and on its Salesforce Task.
    func updateTask(_ item: TaskItem) {
        guard let i = tour.tasks.firstIndex(where: { $0.id == item.id }) else { return }
        tour.tasks[i] = item
        guard let sfId = item.salesforceId, salesforce.isConnected else { return }
        let due = tour.dueDate(item)
        run("Saving checklist item…") {
            var f = SalesforceClient.taskFields(item, due: due, programId: nil)
            f[SFMap["task.phase"]] = nil
            try await self.salesforce.updateTask(sfId, fields: f)
            if let o = item.ownerId { self.tour.tasks[i].ownerName = self.users.first { $0.id == o }?.name }
        }
    }

    func addTask(phase: PhaseID, title: String) {
        var item = TaskItem(phase: phase, title: title, role: "", offsetDays: phase == .wrapup ? phase.defaultWindow.upperBound : phase.defaultWindow.upperBound)
        item.ownerId = currentUserId
        item.ownerName = users.first { $0.id == currentUserId }?.name
        item.dueDate = tour.dueDate(item)
        tour.tasks.append(item)
        guard checklistInSalesforce else { return }
        let due = item.dueDate!, pid = tour.campaignId, localId = item.id
        run("Creating task…") {
            let sfId = try await self.salesforce.createChecklistTask(item, due: due, programId: pid)
            if let i = self.tour.tasks.firstIndex(where: { $0.id == localId }) { self.tour.tasks[i].salesforceId = sfId }
        }
    }

    func deleteTask(_ item: TaskItem) {
        tour.tasks.removeAll { $0.id == item.id }
        guard let sfId = item.salesforceId else { return }
        run("Deleting task…") { try await self.salesforce.deleteTask(sfId) }
    }

    func createDriveFolder() {
        run("Creating tour folder and agenda…") { try await self.setUpDrive() }
    }

    /// New folder (named like the program) in the shared study-tour folder, a copy of the agenda
    /// template inside it, and both links on the program in Salesforce.
    func setUpDrive() async throws {
        guard !tour.campaignId.isEmpty else { throw AppError("Select or create the program first.") }
        let existing = try await salesforce.programLinks(programId: tour.campaignId)
        if let f = existing.folder, let fid = DriveStructure.id(from: f) {
            tour.driveFolderId = fid
            if let a = existing.agenda, let aid = DriveStructure.id(from: a) { tour.agendaDocId = aid }
            flash("This program already has a Drive folder")
            return
        }
        let folder = try await google.createFolder(name: tour.name, parent: DriveStructure.parentFolderId)
        let agenda = try await google.copyFile(DriveStructure.agendaTemplateId, name: DriveStructure.agendaName(program: tour.name), parent: folder)
        try await salesforce.setProgramLinks(programId: tour.campaignId, folder: DriveStructure.folderURL(folder),
                                             agenda: DriveStructure.slidesURL(agenda))
        tour.driveFolderId = folder
        tour.agendaDocId = agenda
        flash("Tour folder and agenda created in the shared Drive")
    }

    // MARK: Participants & cleansing

    func loadParticipants() {
        run("Loading members…") {
            self.participants = try await self.salesforce.leads(campaignId: self.tour.campaignId)
            self.report = nil
            self.flash("\(self.participants.count) members loaded")
        }
    }

    var cleanser: Cleanser { Cleanser(settings: settings.cleansing, tourEnd: tour.endDate, requiredFields: requiredFields) }

    func runCleansing() {
        report = cleanser.run(participants)
        selectedChanges = Set(report?.changes.map(\.id) ?? [])
    }

    /// Selects only the phone-number conversions (international format) and saves them.
    func convertAllPhoneNumbers() {
        guard let report else { return }
        selectedChanges = Set(report.changes.filter { $0.field == .phone || $0.field == .emergencyPhone }.map(\.id))
        applySelectedChanges()
    }

    // MARK: Mails to members about their ID document (no document data in the mail; every mail is logged)

    /// Members who were asked to update / reminded in this session (shown in the list).
    var passportRequestSent: Set<String> = []
    var documentReminderSent: Set<String> = []

    /// Attendees with a problem in their ID-document data.
    var membersWithPassportProblems: [(member: Participant, problems: [PassportProblem])] {
        let c = cleanser
        return participants.map { ($0, c.passportProblems($0)) }.filter { !$0.1.isEmpty }
    }

    func requestPassportUpdates(_ ids: [String]) {
        let c = cleanser
        let targets = participants.filter { ids.contains($0.id) }.map { ($0, c.passportProblems($0)) }.filter { !$0.1.isEmpty }
        sendMemberMails(label: "update requests", targets.map { member, problems in
            (member, Assistant.passportUpdateMail(firstName: member[.firstName], tourName: tour.name, problems: problems,
                                                  signOffName: signOffName))
        }) { self.passportRequestSent.insert($0) }
    }

    func sendDocumentReminders() {
        sendMemberMails(label: "reminders", participants.map { member in
            (member, Assistant.bringDocumentMail(firstName: member[.firstName], tourName: tour.name,
                                                 documentType: member[.identificationType], tourStart: tour.startDate,
                                                 signOffName: signOffName))
        }) { self.documentReminderSent.insert($0) }
    }

    /// Sends one mail per member via Gmail and logs each on the member in Salesforce. One failure doesn't stop the rest.
    private func sendMemberMails(label: String, _ mails: [(Participant, (subject: String, body: String))], sent mark: @escaping (String) -> Void) {
        run("Sending \(mails.count) \(label)…") {
            var sent = 0, noEmail = 0, failed = 0, notLogged = 0
            for (member, mail) in mails {
                guard EmailRules.isValid(member[.email]) else { noEmail += 1; continue }
                do {
                    let how = try await self.sendViaGmail(to: member[.email], subject: mail.subject, body: mail.body,
                                                          whoId: member.id, whatId: nil)
                    if how.contains("failed") || how.contains("no database record") { notLogged += 1 }
                    sent += 1
                    mark(member.id)
                } catch { failed += 1 }
            }
            var note = "\(label.prefix(1).uppercased() + label.dropFirst()) sent to \(sent) members"
            if noEmail > 0 { note += " · \(noEmail) without a valid email" }
            if failed > 0 { note += " · \(failed) failed" }
            if notLogged > 0 { note += " · \(notLogged) not logged in the database" }
            if failed > 0 || notLogged > 0 { throw AppError(note) } else { self.flash(note) }
        }
    }

    func applySelectedChanges() {
        guard let report else { return }
        let chosen = report.changes.filter { selectedChanges.contains($0.id) }
        var updates: [String: [ParticipantField: String?]] = [:]
        for c in chosen { updates[c.participantId, default: [:]][c.field] = c.newValue }
        run("Saving \(chosen.count) corrections to the database…") {
            let results = try await self.salesforce.updateLeads(updates)
            let failed = results.filter { !$0.success }
            for c in chosen where !failed.contains(where: { $0.id == c.participantId }) {
                if let i = self.participants.firstIndex(where: { $0.id == c.participantId }) {
                    self.participants[i][c.field] = c.newValue
                }
            }
            self.runCleansing()
            if failed.isEmpty { self.flash("\(chosen.count) corrections saved") }
            else { self.lastError = "\(failed.count) records failed: " + failed.prefix(3).map { "\($0.id): \($0.message)" }.joined(separator: " | ") }
        }
    }

    // MARK: Hosts

    func addHost(accountId: String, name: String) {
        var h = Host(name: name, accountId: accountId)
        run("Loading contacts of \(name)…") {
            h.contacts = try await self.salesforce.contacts(accountId: accountId)
            self.tour.hosts.append(h)
        }
    }

    func refreshContacts(_ hostId: UUID) {
        guard let i = tour.hosts.firstIndex(where: { $0.id == hostId }), let acc = tour.hosts[i].accountId else { return }
        run("Refreshing contacts…") { self.tour.hosts[i].contacts = try await self.salesforce.contacts(accountId: acc) }
    }

    // MARK: Exports

    @discardableResult
    func writeExport(sheet: XLSXWriter.Sheet, fileName: String, containsPassport: Bool, count: Int, upload: Bool) async throws -> ExportRecord {
        let data = XLSXWriter.build([sheet])
        let url = Store.exportsDirectory.appendingPathComponent(fileName)
        try data.write(to: url, options: [.atomic])
        var rec = ExportRecord(fileName: fileName, createdAt: Date(), localPath: url.path, driveFileId: nil,
                               containsPassportData: containsPassport, participantCount: count)
        if upload, google.isConnected, !tour.driveFolderId.isEmpty {
            rec.driveFileId = try await google.upload(name: fileName, data: data,
                mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", parent: tour.driveFolderId)
        }
        return rec
    }

    func exportHost(_ hostId: UUID, upload: Bool) {
        guard let i = tour.hosts.firstIndex(where: { $0.id == hostId }) else { return }
        guard !participants.isEmpty else { lastError = "Load members first (Registration phase)."; return }
        let host = tour.hosts[i]
        let errors = (report?.issues ?? []).filter { $0.severity == .error && ($0.field.map(host.requiredFields.contains) ?? false) }
        run("Exporting list for \(host.name)…") {
            let sheet = ParticipantExport.sheet(host: host, tour: self.tour, participants: self.participants)
            let rec = try await self.writeExport(sheet: sheet, fileName: ParticipantExport.fileName(host: host, tour: self.tour),
                                                 containsPassport: host.requiredFields.contains(where: \.isPassportData),
                                                 count: self.participants.count, upload: upload)
            self.tour.hosts[i].exports.append(rec)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rec.localPath ?? "")])
            self.flash(errors.isEmpty ? "Export created" : "Export created — note: \(errors.count) data errors remain")
        }
    }

    /// Attendance sheet for the road: loads the attending members if needed, then the user chooses where to save it.
    func exportTourLists() {
        run("Preparing attendance list…") {
            if self.participants.isEmpty {
                guard !self.tour.campaignId.isEmpty else { throw AppError("Select the tour's program first.") }
                self.participants = try await self.salesforce.leads(campaignId: self.tour.campaignId)
                self.report = nil
            }
            guard !self.participants.isEmpty else { throw AppError("This program has no attending members yet.") }
            let sorted = self.participants.sorted { $0[.lastName] < $1[.lastName] }
            let attendance = XLSXWriter.Sheet(name: "Attendance", title: "\(self.tour.name) – attendance",
                headers: ["No.", "Last name", "First name", "Organization", "Phone", "Day 1", "Day 2", "Day 3", "Day 4"],
                rows: sorted.enumerated().map { [String($0.offset + 1), $0.element[.lastName], $0.element[.firstName], $0.element[.organization], $0.element[.phone], "", "", "", ""] })
            let data = XLSXWriter.build([attendance])
            let panel = NSSavePanel()
            panel.title = "Save attendance list"
            panel.nameFieldStringValue = "\(self.tour.name.replacingOccurrences(of: "/", with: "-")) – attendance.xlsx"
            panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: [.atomic]) }
            catch { throw AppError("Could not save the attendance list: \(error.localizedDescription)") }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            self.flash("Attendance list saved: \(url.lastPathComponent) (\(sorted.count) attendees)")
        }
    }

    // MARK: Agenda / calendar

    func touchAgenda(_ item: AgendaItem) {
        var i = item
        i.modified = Date()
        var t = tour
        if let idx = t.agenda.firstIndex(where: { $0.id == item.id }) { t.agenda[idx] = i } else { t.agenda.append(i) }
        t.agenda.sort { $0.start < $1.start }
        tour = t
    }

    func deleteAgenda(_ item: AgendaItem) {
        tour.agenda.removeAll { $0.id == item.id }
        run("Removing calendar entries…") {
            if let id = item.salesforceEventId { try await self.salesforce.deleteEvent(id) }
            if let id = item.googleEventId { try await self.google.deleteEvent(calendarId: self.tour.googleCalendarId, eventId: id) }
        }
    }

    func syncAgenda() {
        run("Syncing calendar…") {
            var t = self.tour
            let tz = TimeZone.current.identifier
            for idx in t.agenda.indices where t.agenda[idx].needsSync {
                let item = t.agenda[idx]
                let whatId = item.hostId.flatMap { hid in t.hosts.first { $0.id == hid }?.accountId }
                    ?? (t.campaignId.isEmpty ? nil : t.campaignId)
                if self.salesforce.isConnected {
                    t.agenda[idx].salesforceEventId = try await self.salesforce.upsertEvent(item, whatId: whatId, tourName: t.name)
                }
                if self.google.isConnected {
                    t.agenda[idx].googleEventId = try await self.google.upsertEvent(calendarId: t.googleCalendarId, item: item,
                                                                                   tourName: t.name, attendees: [], timeZone: tz)
                }
                t.agenda[idx].lastSynced = Date()
                self.tour = t
            }
            // The agenda presentation (copied from the template) is updated from the Opportunities — see README.
            self.flash("Calendar updated")
        }
    }

    // MARK: Monitoring

    func refreshMetrics() async {
        if google.isConnected {
            unreadCount = try? await google.estimate(query: "is:unread " + settings.google.inboxQuery)
        }
        if salesforce.isConnected, !tour.campaignId.isEmpty {
            memberCount = try? await salesforce.memberCount(campaignId: tour.campaignId)
            incompletePassports = try? await salesforce.incompletePassportCount(campaignId: tour.campaignId)
        }
    }

    // MARK: Knowledge base

    /// Current knowledge base text; re-read at most every 10 minutes (or when forced / the URL changed).
    func knowledgeBaseText(force: Bool = false) async -> String {
        if salesforce.isConnected, !tour.campaignId.isEmpty,
           let url = try? await salesforce.knowledgeBaseURL(programId: tour.campaignId) {
            knowledgeBaseURL = url
        } else if tour.campaignId.isEmpty {
            knowledgeBaseURL = KnowledgeBase.defaultURL
        }
        let fresh = kbLoadedAt.map { Date().timeIntervalSince($0) < 600 } ?? false
        if !force, fresh, kbLoadedURL == knowledgeBaseURL { return kbText }
        guard google.isConnected else { knowledgeBaseStatus = "Connect Google to read the knowledge base"; return kbText }
        guard let id = KnowledgeBase.documentId(from: knowledgeBaseURL) else { knowledgeBaseStatus = "Not a Google Docs link"; return "" }
        do {
            kbText = try await google.documentText(id: id)
            kbLoadedAt = Date(); kbLoadedURL = knowledgeBaseURL
            knowledgeBaseStatus = "Loaded \(kbText.count) characters at \(Date().formatted(date: .omitted, time: .shortened))"
        } catch let e as APIError where e.status == 403 || e.status == 404 {
            knowledgeBaseStatus = "No access — ask the owner to share the document with your Google account"
        } catch {
            knowledgeBaseStatus = "Could not read: \(error.localizedDescription)"
        }
        return kbText
    }

    /// Appends new, general facts from an approved reply to the knowledge base document.
    func learnFromReply(question: String, answer: String) async {
        guard gemini.isConfigured, google.isConnected, let id = KnowledgeBase.documentId(from: knowledgeBaseURL) else { return }
        let kb = await knowledgeBaseText(force: true)
        let p = KnowledgeBase.learningPrompt(question: question, answer: answer, knowledgeBase: kb)
        guard let text = try? await gemini.generate(system: p.system, prompt: p.prompt, json: true) else { return }
        let facts = KnowledgeBase.parseFacts(text)
        guard !facts.isEmpty else { return }
        do {
            try await google.appendToDocument(id: id, text: KnowledgeBase.appendix(facts: facts))
            _ = await knowledgeBaseText(force: true)
            flash("Knowledge base: \(facts.count) new fact\(facts.count == 1 ? "" : "s") added")
        } catch {
            knowledgeBaseStatus = "Could not update the knowledge base: \(error.localizedDescription)"
        }
    }

    func setKnowledgeBase(url: String) {
        run("Saving knowledge base link…") {
            guard KnowledgeBase.documentId(from: url) != nil else { throw AppError("Please paste a Google Docs link.") }
            try await self.salesforce.setKnowledgeBaseURL(programId: self.tour.campaignId, url: url)
            self.knowledgeBaseURL = url
            _ = await self.knowledgeBaseText(force: true)
        }
    }

    // MARK: Inbox

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let minutes = max(self?.settings.assistant.pollMinutes ?? 0, 5)
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                guard let self, self.google.isConnected, self.busy == nil, !self.scanning, self.settings.assistant.pollMinutes > 0 else { continue }
                self.scanning = true
                await self.processInbox()
                self.scanning = false
            }
        }
    }

    private(set) var scanning = false

    func refreshInbox() {
        guard !scanning else { return }   // never two scans at once
        scanning = true
        run("Scanning inbox…") { defer { self.scanning = false }; await self.processInbox() }
    }

    /// Opening the Inbox scans automatically, unless the last scan is less than `maxAge` seconds old.
    func scanInboxIfStale(maxAge: TimeInterval = 120) {
        guard googleConnected, !scanning else { return }
        if let last = lastScan, Date().timeIntervalSince(last) < maxAge { return }
        refreshInbox()
    }

    private func lookupSender(_ address: String) async -> [SFRecordRef] {
        if let c = senderCache[address] { return c }
        guard salesforce.isConnected else { return [] }
        let r = ((try? await salesforce.findUsers(email: address)) ?? []) + ((try? await salesforce.findPeople(email: address)) ?? [])
        senderCache[address] = r
        return r
    }

    private func gmailLabelQuery(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
    }

    /// Scan → identify sender → triage → highlight → log activity → propose records → draft replies (never sent automatically).
    func processInbox() async {
        let s = settings
        do {
            if myMailAddress.isEmpty { myMailAddress = (try? await google.myAddress()) ?? "" }
            let messages = try await google.listMessages(query: s.google.inboxQuery, max: 50)
            let kb = await knowledgeBaseText()
            let loggedLabel = try await google.labelId("Study Tour/Logged")
            let answeredLabel = try await google.labelId(s.google.answeredLabel)
            var items: [InboxItem] = []

            for m in messages {
                let matches = await lookupSender(m.fromAddress)
                let identity = Assistant.identify(address: m.fromAddress, tour: tour, salesforceMatches: matches)
                var item = inbox.first(where: { $0.id == m.id }) ?? InboxItem(message: m, identity: identity, triage: nil, important: false)
                item.identity = identity
                item.logged = m.labelIds.contains(loggedLabel)
                item.answered = item.answered || m.labelIds.contains(answeredLabel) || tour.handledMessageIds.contains(m.id)
                if identity.kind == .team { items.append(item); continue }

                // 1. triage (cached per message)
                if let cached = triageCache[m.id] { item.triage = cached }
                else if gemini.isConfigured {
                    let p = Assistant.triagePrompt(m, identity: identity, tour: tour, knowledgeBase: kb, redact: s.gemini.redactNumbers)
                    if let text = try? await gemini.generate(system: p.system, prompt: p.prompt, json: true),
                       let t = Assistant.decode(MailTriage.self, from: text) {
                        triageCache[m.id] = t
                        item.triage = t
                    }
                }

                // 2. importance: officials always, urgent keywords, or model says high
                let wasImportant = item.important
                item.important = identity.kind == .official || (item.triage?.isHigh ?? false)
                    || Assistant.hasUrgentKeyword(m, keywords: s.assistant.urgentKeywords)
                if item.important && !wasImportant && !m.labelIds.contains("STARRED") {
                    try? await google.addLabels(m.id, names: [s.google.importantLabel], star: true)
                }

                // 3. track as Salesforce activity
                let related = item.triage?.relatedToTour ?? (identity.kind != .unknown)
                if related, !item.logged, let rec = identity.record, rec.kind != .account {
                    try? await salesforce.logEmailTask(whoId: rec.id, whatId: rec.accountId, subject: m.subject,
                                                       body: MailBody.stripQuoted(m.body), date: m.date,
                                                       direction: .inbound, counterpart: m.fromAddress)
                    try? await google.addLabels(m.id, names: ["Study Tour/Logged"])
                    item.logged = true
                }

                // 4. propose new Lead / Contact for unknown, tour-related senders
                if item.proposal == nil, let t = item.triage, var p = Assistant.recordProposal(m, triage: t, identity: identity) {
                    p.possibleDuplicates = (try? await salesforce.findPeople(firstName: p.firstName, lastName: p.lastName)) ?? []
                    if p.kind == .contact {
                        let domain = p.email.split(separator: "@").last.map(String.init)
                        p.existingAccount = (try? await salesforce.findAccounts(name: p.organization, domain: domain))?.first
                    }
                    item.proposal = p
                }

                // 5. draft a reply for every mail that needs one — the user reviews and sends it, nothing is sent automatically
                if !item.answered, identity.kind != .team, let t = item.triage, t.needsReply,
                   t.relatedToTour || identity.kind != .unknown, item.draft == nil, gemini.isConfigured {
                    let p = Assistant.replyPrompt(m, sender: identity.kind, greeting: identity.record?.greeting,
                                                  signOffName: signOffName, signOffFullName: signOffFullName,
                                                  tour: tour, knowledgeBase: kb,
                                                  settings: s.assistant, redact: s.gemini.redactNumbers)
                    if let text = try? await gemini.generate(system: p.system, prompt: p.prompt, json: true, temperature: 0.3),
                       let d = Assistant.decode(DraftReply.self, from: text) {
                        item.draft = d
                        item.draftBody = ensureSignOff(d.body, to: identity.kind)
                        item.status = d.confident && (d.missingInfo ?? []).isEmpty && !d.body.contains("[CHECK")
                            ? "Draft ready — review and send" : "Draft ready — fill in the [CHECK] parts before sending"
                    }
                }
                items.append(item)
            }
            inbox = items.sorted { ($0.important ? 1 : 0, $0.message.date) > ($1.important ? 1 : 0, $1.message.date) }
            lastScan = Date()
            await refreshMetrics()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Sends from the Fulbright Gmail account (full thread stays in Gmail), then logs it as an
    /// activity on the Lead / Contact (+ Account) in Salesforce.
    @discardableResult
    func sendViaGmail(to: String, cc: [String] = [], subject: String, body: String, threadId: String? = nil,
                      inReplyTo: String? = nil, references: String? = nil,
                      attachments: [MailComposer.Attachment] = [],
                      whoId: String?, whatId: String?) async throws -> String {
        // "via …" line right under the name, then the user's own Gmail signature (once; replies already have it)
        let body = Assistant.withFooter(body, signature: (try? await google.gmailSignature()) ?? "")
        let raw = MailComposer.raw(to: to, cc: cc, subject: subject, body: body, attachments: attachments,
                                   inReplyTo: inReplyTo, references: references)
        try await google.send(raw: raw, threadId: threadId)
        guard let whoId else { return "Sent via Gmail (no database record to log on)" }
        do {
            let note = attachments.isEmpty ? "" : "\n\nAttachments: " + attachments.map(\.fileName).joined(separator: ", ")
            try await salesforce.logEmailTask(whoId: whoId, whatId: whatId, subject: subject, body: body + note,
                                              date: Date(), direction: .outbound, counterpart: to)
            return "Sent via Gmail, logged in the database"
        } catch {
            return "Sent via Gmail — logging in the database failed: \(error.localizedDescription)"
        }
    }

    /// CCs for the reply: what the user set, else everyone who was on the original mail ("reply all").
    func replyCC(for item: InboxItem) -> [String] {
        item.replyCC ?? Assistant.replyCC(item.message, ownAddress: myMailAddress)
    }

    func setReplyCC(_ itemId: String, _ cc: [String]) {
        if let i = inbox.firstIndex(where: { $0.id == itemId }) { inbox[i].replyCC = cc }
    }

    /// Replies in the original Gmail thread and marks the message as answered.
    @discardableResult
    func sendReply(_ item: InboxItem, body: String) async throws -> String {
        let m = item.message
        let full = Assistant.composeBody(body, signature: (try? await google.gmailSignature()) ?? "", original: m)
        // incoming email on the member (if the scan has not logged it yet)
        if !item.logged, let rec = item.identity.record, rec.kind == .lead || rec.kind == .contact {
            try? await salesforce.logEmailTask(whoId: rec.id, whatId: rec.accountId, subject: m.subject, body: MailBody.stripQuoted(m.body),
                                               date: m.date, direction: .inbound, counterpart: m.fromAddress)
            try? await google.addLabels(m.id, names: ["Study Tour/Logged"])
        }
        // outgoing reply via Gmail (same thread), logged on the member
        let how = try await sendViaGmail(to: m.fromAddress, cc: replyCC(for: item), subject: Assistant.replySubject(m.subject), body: full,
                                         threadId: m.threadId, inReplyTo: m.rfcMessageId, references: m.references,
                                         whoId: item.identity.record?.id, whatId: item.identity.record?.accountId)
        try? await google.addLabels(m.id, names: [settings.google.answeredLabel])
        try? await google.archive(m.id)
        tour.handledMessageIds.append(m.id)
        // learn: new general facts from the approved answer go into the knowledge base
        Task { await self.learnFromReply(question: MailBody.stripQuoted(m.body), answer: body) }
        return how
    }

    func sendManually(_ itemId: String) {
        guard let item = inbox.first(where: { $0.id == itemId }) else { return }
        run("Sending via Gmail…") {
            let how = try await self.sendReply(item, body: item.draftBody)
            if let j = self.inbox.firstIndex(where: { $0.id == itemId }) {
                self.inbox[j].answered = true
                self.inbox[j].status = how
            }
            self.flash(how)
        }
    }

    func draftReply(_ itemId: String) {
        guard let i = inbox.firstIndex(where: { $0.id == itemId }) else { return }
        let m = inbox[i].message
        let sender = inbox[i].identity.kind
        let greeting = inbox[i].identity.record?.greeting
        run("Drafting reply with Gemini…") {
            let kb = await self.knowledgeBaseText()
            let p = Assistant.replyPrompt(m, sender: sender, greeting: greeting, signOffName: self.signOffName,
                                          signOffFullName: self.signOffFullName, tour: self.tour, knowledgeBase: kb, settings: self.settings.assistant, redact: self.settings.gemini.redactNumbers)
            let text = try await self.gemini.generate(system: p.system, prompt: p.prompt, json: true, temperature: 0.3)
            guard let d = Assistant.decode(DraftReply.self, from: text) else { throw AppError("Could not read Gemini's reply") }
            if let j = self.inbox.firstIndex(where: { $0.id == itemId }) {
                self.inbox[j].draft = d
                self.inbox[j].draftBody = self.ensureSignOff(d.body, to: sender)
            }
        }
    }

    /// Creates the proposed Lead or Contact (+Account) after re-checking that it doesn't exist.
    /// Archives a mail that needs no action: removed from the Gmail inbox and from the list — nothing is logged or sent.
    func archiveMail(_ itemId: String) {
        guard let i = inbox.firstIndex(where: { $0.id == itemId }) else { return }
        let next = inbox.indices.contains(i + 1) ? inbox[i + 1].id : (i > 0 ? inbox[i - 1].id : nil)
        run("Archiving…") {
            try await self.google.archive(itemId)
            self.inbox.removeAll { $0.id == itemId }
            if self.inboxSelection == itemId { self.inboxSelection = next }
            self.flash("Archived")
        }
    }

    /// "Add sender to Salesforce": prepares the review card for an unknown sender (nothing is written yet).
    func proposeRecord(_ itemId: String) {
        guard let item = inbox.first(where: { $0.id == itemId }) else { return }
        run("Checking the database for this sender…") {
            var p = Assistant.manualProposal(item.message, triage: item.triage)
            if let existing = try await self.salesforce.findPeople(email: p.email).first {
                self.senderCache[p.email] = [existing]
                throw AppError("\(existing.name) already exists in the database as \(existing.kind.displayName).")
            }
            p.possibleDuplicates = (try? await self.salesforce.findPeople(firstName: p.firstName, lastName: p.lastName)) ?? []
            let domain = p.email.split(separator: "@").last.map(String.init)
            p.existingAccount = (try? await self.salesforce.findAccounts(name: p.organization, domain: domain))?.first
            if let i = self.inbox.firstIndex(where: { $0.id == itemId }) { self.inbox[i].proposal = p }
            self.reviewingProposal = itemId
        }
    }

    func createRecord(_ itemId: String, proposal p: RecordProposal) {
        guard let i = inbox.firstIndex(where: { $0.id == itemId }) else { return }
        let m = inbox[i].message
        reviewingProposal = nil
        run("Creating \(p.kind.displayName)…") {
            // Duplicate check right before writing.
            if let existing = try await self.salesforce.findPeople(email: p.email).first {
                self.senderCache[p.email] = [existing]
                self.inbox[i].proposal = nil
                throw AppError("\(existing.name) already exists as \(existing.kind.displayName) — nothing created.")
            }
            let whoId: String
            var whatId: String?
            switch p.kind {
            case .lead:
                whoId = try await self.salesforce.create("Lead", [
                    "FirstName": p.firstName, "LastName": p.lastName.isEmpty ? p.email : p.lastName, "Email": p.email,
                    "Company": p.organization.isEmpty ? "[not provided]" : p.organization,
                    "Title": p.jobTitle, SFMap["member.leadSource"]: SFMap["member.leadSourceValue"]])
                try await self.salesforce.addToCampaign(leadId: whoId, campaignId: self.tour.campaignId)
            case .contact:
                var accountId = p.existingAccount?.id
                if accountId == nil {
                    let domain = p.email.split(separator: "@").last.map(String.init) ?? ""
                    var fields: [String: Any] = ["Name": p.organization.isEmpty ? domain : p.organization]
                    if !EmailRules.freemailDomains.contains(domain) { fields["Website"] = domain }
                    accountId = try await self.salesforce.create("Account", fields)
                }
                whatId = accountId
                var contact: [String: Any] = [
                    "FirstName": p.firstName, "LastName": p.lastName.isEmpty ? p.email : p.lastName,
                    "Email": p.email, "Title": p.jobTitle, "AccountId": accountId!]
                if p.vip, try await self.salesforce.hasContactVIP() { contact[SFMap["contact.vip"]] = true }
                if try await self.salesforce.fieldNames(of: "Contact").contains(SFMap["contact.greeting"]) {
                    contact[SFMap["contact.greeting"]] = String(Assistant.defaultGreeting(suggested: p.greeting, firstName: p.firstName).prefix(100))
                }
                whoId = try await self.salesforce.create("Contact", contact)
            }
            try await self.salesforce.logEmailTask(whoId: whoId, whatId: whatId, subject: m.subject,
                                                   body: MailBody.stripQuoted(m.body), date: m.date,
                                                   direction: .inbound, counterpart: m.fromAddress)
            try? await self.google.addLabels(m.id, names: ["Study Tour/Logged"])
            self.senderCache[p.email] = nil
            self.inbox[i].proposal = nil
            self.inbox[i].logged = true
            self.inbox[i].identity = SenderIdentity(kind: p.kind == .lead ? .attendee : .official,
                record: SFRecordRef(kind: p.kind == .lead ? .lead : .contact, id: whoId, name: "\(p.firstName) \(p.lastName)",
                                    email: p.email, accountId: whatId, accountName: p.organization,
                                    vip: p.kind == .contact && p.vip,
                                    greeting: p.kind == .contact ? Assistant.defaultGreeting(suggested: p.greeting, firstName: p.firstName) : nil),
                source: "Created now")
            self.flash("\(p.kind.displayName.capitalized) created and email logged")
        }
    }

    // MARK: Thank-you program for officials

    func createThankYouProgram() {
        run("Creating thank-you program…") {
            let name = "\(self.tour.name) – Thank-you officials"
            let id = try await self.salesforce.createCampaign(name: name, parentId: self.tour.campaignId)
            var count = 0
            for h in self.tour.hosts where h.status != .declined {
                for c in h.contacts { try await self.salesforce.addContactToCampaign(contactId: c.id, campaignId: id); count += 1 }
            }
            self.tour.programs.append(LinkedProgram(id: id, name: name, purpose: "Thank-you officials"))
            self.flash("Program created with \(count) officials")
        }
    }

    func draftThankYou(host: Host, contact: HostContact) async throws -> String {
        let df = DateFormatter(); df.dateStyle = .long
        let visit = host.visitDate.map { df.string(from: $0) } ?? "our visit"
        let p = """
        Write a short, warm thank-you email (body only, no subject, no signature) from the organisers of the \
        Fulbright study tour "\(tour.name)" to \(contact.name)\(contact.title.isEmpty ? "" : " (\(contact.title))") of \(host.name) \
        for hosting the group on \(visit). Formal register. Same language as the institution's country would expect \
        (German for German institutions, otherwise English). Max 120 words. Notes from the team: \(host.notes)
        """
        return try await gemini.generate(system: "You write formal correspondence for a non-profit alumni association.", prompt: p, json: false, temperature: 0.4)
    }

    func sendThankYou(host: Host, contact: HostContact, subject: String, body: String) {
        run("Sending thank-you to \(contact.name)…") {
            let full = self.ensureSignOff(body, to: .official)   // thank-you mails go to officials
            let how = try await self.sendViaGmail(to: contact.email, subject: subject, body: full,
                                                  whoId: contact.id, whatId: host.accountId)
            self.flash(how)
        }
    }

    // MARK: Attendee lists for host organizations

    func loadHostVisits() {
        guard !tour.campaignId.isEmpty else { return }
        run("Loading host visits (Opportunities)…") {
            self.hostVisits = try await self.salesforce.hostVisits(programId: self.tour.campaignId)
        }
    }

    /// Downloads the host's Excel form from the Opportunity, maps its columns (Gemini sees headers only),
    /// fills in the attending members locally and prepares the email — for review before sending.
    func prepareHostList(_ visit: HostVisit) {
        run("Preparing attendee list for \(visit.organization)…") {
            guard let file = try await self.salesforce.spreadsheets(on: visit.id).first else {
                throw AppError("No Excel form attached to the host visit “\(visit.name)”. Attach the host's template to the host visit in the database first.")
            }
            let template = try XLSXTemplate(data: try await self.salesforce.download(versionId: file.id))
            let preview = try template.preview()
            var mapping: TemplateMapping?
            var source = "header keywords"
            if self.gemini.isConfigured {
                let p = TemplateMapper.prompt(preview)
                if let text = try? await self.gemini.generate(system: p.system, prompt: p.prompt, json: true),
                   let m = TemplateMapper.parse(text, preview: preview) { mapping = m; source = "Gemini" }
            }
            guard let base = mapping ?? TemplateMapper.fallback(preview) else {
                throw AppError("Could not recognise the columns of “\(file.title)”. Please check the form.")
            }
            if self.participants.isEmpty {
                self.participants = try await self.salesforce.leads(campaignId: self.tour.campaignId)
            }
            var d = HostListDraft(visit: visit, file: file, template: template, mapping: try template.enrich(base), mappingSource: source)
            d.subject = "Attendee list – \(self.tour.name)\(visit.visitStart.map { " – visit on " + $0.formatted(date: .long, time: .omitted) } ?? "")"
            let greeting = visit.recipientGreeting.isEmpty ? "Dear \(visit.recipientName.isEmpty ? "Sir or Madam" : visit.recipientName)," :
                (visit.recipientGreeting.hasSuffix(",") ? visit.recipientGreeting : visit.recipientGreeting + ",")
            d.body = """
            \(greeting)

            please find attached the list of participants of the Fulbright study tour “\(self.tour.name)”\(visit.visitStart.map { " for our visit on " + $0.formatted(date: .long, time: .shortened) } ?? ""), entered in your form.

            Please do not hesitate to contact us if you need any further information.

            \(Assistant.signOff(self.signOffFullName))
            """
            try self.refill(&d)
            self.hostListDrafts[visit.id] = d
        }
    }

    /// Re-applies the (possibly edited) mapping to the template.
    func refill(_ d: inout HostListDraft) throws {
        d.filled = try d.template.filled(with: participants, mapping: d.mapping)
        d.participantCount = participants.count
        d.missing = d.mapping.columns.compactMap { c -> String? in
            guard case .field(let f) = c.source else { return nil }
            let n = participants.filter { $0[f].isEmpty }.count
            return n > 0 ? "\(n) member(s) without \(f.label) (column \(c.column))" : nil
        }
        let url = Store.exportsDirectory.appendingPathComponent(d.fileName(tour: tour.name))
        try d.filled?.write(to: url, options: [.atomic])
        d.localURL = url
    }

    func updateMapping(_ visitId: String, column: String, source: ColumnSource) {
        guard var d = hostListDrafts[visitId], let i = d.mapping.columns.firstIndex(where: { $0.column == column }) else { return }
        d.mapping.columns[i].source = source
        do { try refill(&d); hostListDrafts[visitId] = d } catch { lastError = error.localizedDescription }
    }

    /// Sends the filled form via Gmail to the Opportunity's recipient and logs it in Salesforce:
    /// email activity on the recipient (+ Opportunity) and a data-disclosure record on every member.
    func sendHostList(_ visitId: String) {
        guard let d = hostListDrafts[visitId], let data = d.filled else { return }
        run("Sending attendee list to \(d.visit.organization)…") {
            guard EmailRules.isValid(d.visit.recipientEmail) else {
                throw AppError("Set the “Attendee List Recipient” (with email) on the Opportunity first.")
            }
            let how = try await self.sendViaGmail(to: d.visit.recipientEmail, subject: d.subject, body: d.body,
                                                  attachments: [.init(fileName: d.fileName(tour: self.tour.name), mimeType: MailComposer.Attachment.xlsxMime, data: data)],
                                                  whoId: d.visit.recipientId, whatId: d.visit.id)
            // record of disclosure on each member (GDPR accountability)
            let fields = d.mapping.columns.compactMap { c -> ParticipantField? in if case .field(let f) = c.source { return f } else { return nil } }
            try? await self.salesforce.createTasks(self.participants.map {
                ["WhoId": $0.id, "Subject": "Data protection: attendee data sent to \(d.visit.organization)",
                 "Description": "Shared fields: \(fields.map(\.label).joined(separator: ", ")).\nRecipient: \(d.visit.recipientName) <\(d.visit.recipientEmail)>.\nVisit: \(d.visit.name).",
                 "Status": SFMap["task.completedValue"], "Priority": SFMap["task.priorityValue"], "ActivityDate": Dates.iso(Date())]
            })
            self.hostListDrafts[visitId]?.sentAt = Date()
            // passport data stays in Salesforce only: remove the local copy of the filled form
            if let url = d.localURL { try? FileManager.default.removeItem(at: url) }
            self.hostListDrafts[visitId]?.localURL = nil
            self.flash(how)
        }
    }

    // MARK: Data protection scrub

    /// Clears the fixed set of personal-data fields on ALL members of the program, whatever their attendance status.
    func scrubSalesforce() {
        let fields = ParticipantField.defaultScrub
        run("Deleting passport data…") {
            let ids = try await self.salesforce.programLeadIdsWithData(campaignId: self.tour.campaignId, in: fields)
            let updates = Dictionary(uniqueKeysWithValues: ids.map { ($0, Dictionary(uniqueKeysWithValues: fields.map { ($0, Optional<String>.none) })) })
            let results = try await self.salesforce.updateLeads(updates)
            let ok = results.filter(\.success).count
            // Data-protection record on each affected member (Lead)
            try await self.salesforce.createTasks(results.filter(\.success).map {
                SalesforceClient.dataProtectionTask(leadId: $0.id, fields: fields, scope: "Program \(self.tour.campaignName)")
            })
            self.tour.scrubLog.append(ScrubLogEntry(date: Date(), action: "Database fields cleared",
                detail: fields.map(\.label).joined(separator: ", ") + (results.count > ok ? " — \(results.count - ok) failed" : ""), count: ok))
            for i in self.participants.indices { for f in fields { self.participants[i].values[f] = nil } }
            self.flash("Cleared on \(ok) members")
        }
    }

    /// Admin only: clears passport fields on every (unconverted) Lead in the org.
    func scrubOrgWide() {
        let fields = ParticipantField.defaultScrub
        run("Deleting passport data for all members…") {
            guard try await self.salesforce.hasModifyAllData() else { throw AppError("Only database administrators (Modify All Data) can run the deletion for all members.") }
            let ids = try await self.salesforce.leadIdsWithData(in: fields)
            let updates = Dictionary(uniqueKeysWithValues: ids.map { ($0, Dictionary(uniqueKeysWithValues: fields.map { ($0, Optional<String>.none) })) })
            let results = try await self.salesforce.updateLeads(updates)
            let ok = results.filter(\.success).count
            try await self.salesforce.createTasks(results.filter(\.success).map {
                SalesforceClient.dataProtectionTask(leadId: $0.id, fields: fields, scope: "Org-wide deletion by an administrator")
            })
            let converted = try await self.salesforce.convertedLeadCountWithData(in: fields)
            self.tour.scrubLog.append(ScrubLogEntry(date: Date(), action: "ALL MEMBERS: database fields cleared",
                detail: fields.map(\.label).joined(separator: ", ")
                    + (results.count > ok ? " — \(results.count - ok) failed" : "")
                    + (converted > 0 ? " — \(converted) converted members are read-only and were skipped" : ""), count: ok))
            for i in self.participants.indices { for f in fields { self.participants[i].values[f] = nil } }
            self.flash("Cleared on \(ok) members org-wide")
        }
    }

    func deleteExports() {
        run("Deleting exported files…") {
            var t = self.tour
            var n = 0
            for h in t.hosts.indices {
                for e in t.hosts[h].exports.indices where t.hosts[h].exports[e].deletedAt == nil {
                    let rec = t.hosts[h].exports[e]
                    if let p = rec.localPath { try? FileManager.default.removeItem(atPath: p) }
                    if let id = rec.driveFileId { try await self.google.deleteFile(id) }
                    t.hosts[h].exports[e].deletedAt = Date()
                    n += 1
                }
            }
            // tour lists and any other leftovers in the export folder
            for f in (try? FileManager.default.contentsOfDirectory(atPath: Store.exportsDirectory.path)) ?? [] {
                try? FileManager.default.removeItem(at: Store.exportsDirectory.appendingPathComponent(f)); n += 1
            }
            t.scrubLog.append(ScrubLogEntry(date: Date(), action: "Export files deleted", detail: "Local + Google Drive", count: n))
            self.tour = t
            self.flash("\(n) files deleted")
        }
    }

    // MARK: Team chat (Google Chat space, as the signed-in Google user)

    var chatSpace: String { settings.google.effectiveChatSpace }
    var chatReady: Bool { googleConnected && !chatSpace.isEmpty }

    /// Puts text into the chat composer for review — nothing is posted until the user presses Send.
    func shareToTeam(_ text: String) {
        chatDraft = text
        if !chatReady { flash("Choose the team's Google Chat space in Settings first") }
    }

    func refreshChat() async {
        guard chatReady else { chatMessages = []; return }
        let space = chatSpace
        do {
            if chatSpaceLoaded != space {
                chatMessages = []
                myChatUserId = (try? await google.chatMyUserId(space: space)) ?? ""
                if settings.google.chatSpaceTitle.isEmpty, let s = try? await google.chatSpace(space) {
                    settings.google.chatSpaceTitle = s.name
                }
                chatSpaceLoaded = space
            }
            var msgs = try await google.chatMessages(space: space)
            for i in msgs.indices where msgs[i].senderName.isEmpty {
                msgs[i].senderName = await chatName(msgs[i].senderId)
            }
            chatMessages = msgs
            chatError = nil
        } catch {
            chatError = error.localizedDescription
        }
    }

    private func chatName(_ userId: String) async -> String {
        if userId == myChatUserId { return "You" }
        if let n = chatNames[userId] { return n }
        let n = (try? await google.personName(chatUserId: userId)).flatMap { $0.isEmpty ? nil : $0 } ?? "Team member"
        chatNames[userId] = n
        return n
    }

    func sendChat() {
        let text = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard chatReady, !text.isEmpty, !chatSending else { return }
        chatSending = true
        Task {
            defer { chatSending = false }
            do {
                try await google.postChatMessage(space: chatSpace, text: text)
                chatDraft = ""
                await refreshChat()
            } catch {
                chatError = error.localizedDescription
            }
        }
    }

    func startChatPolling() {
        chatTask?.cancel()
        chatTask = Task { [weak self] in
            while !Task.isCancelled {
                // poll only while the app is in front (saves quota); otherwise check once a minute
                if let self, self.chatReady, NSApp.isActive || self.chatMessages.isEmpty { await self.refreshChat() }
                try? await Task.sleep(for: .seconds(NSApp.isActive ? 20 : 60))
            }
        }
    }
}
