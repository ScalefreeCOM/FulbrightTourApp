import SwiftUI
import AppKit
import StudyToursCore

// MARK: - Overview

struct OverviewView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let tour = state.tour
        let df = Date.FormatStyle(date: .abbreviated, time: .omitted)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FulbrightHeader(title: state.tourTitle,
                                subtitle: "\(tour.city.isEmpty ? "City not set" : tour.city) · \(tour.startDate.formatted(df)) – \(tour.endDate.formatted(df))",
                                systemImage: "globe.europe.africa")
                Card(title: "Timeline") {
                    ForEach(PhaseID.allCases) { p in
                        let (s, e) = tour.window(p)
                        HStack {
                            Image(systemName: p.systemImage).frame(width: 22).foregroundStyle(Theme.skyOnDark)
                            Text(p.title).frame(width: 230, alignment: .leading)
                            Text("\(s.formatted(df)) – \(e.formatted(df))").font(.caption).foregroundStyle(.secondary).frame(width: 190, alignment: .leading)
                            ProgressView(value: tour.progress(p)).tint(Theme.fbCyan)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { state.selection = .phase(p) }
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    Card(title: "Next 14 days") {
                        let upcoming = tour.tasks.filter { !$0.done }
                            .filter { let d = tour.dueDate($0); return d >= Calendar.current.startOfDay(for: Date()) && d <= Date().addingTimeInterval(14 * 86400) }
                            .sorted { tour.dueDate($0) < tour.dueDate($1) }
                        if upcoming.isEmpty { Text("Nothing due.").foregroundStyle(.secondary) }
                        ForEach(upcoming) { t in
                            HStack { Text(tour.dueDate(t).formatted(df)).font(.caption).frame(width: 90, alignment: .leading); Text(t.title) }
                        }
                    }
                    Card(title: "Tour status") {
                        LabeledContent("Program", value: tour.campaignName.isEmpty ? "not linked" : tour.campaignName)
                        LabeledContent("Hosts confirmed", value: "\(tour.hosts.filter { $0.status == .confirmed || $0.status == .submitted }.count) / \(tour.hosts.count)")
                        LabeledContent("Members loaded", value: "\(state.participants.count)")
                        LabeledContent("Agenda items", value: "\(tour.agenda.count)")
                        LabeledContent("Important mails", value: "\(state.inbox.filter { $0.important && !$0.answered }.count)")
                    }
                }
            }
            .padding(.bottom, 60)
        }
    }
}

// MARK: - Phase screen

struct PhaseView: View {
    @Environment(AppState.self) private var state
    let phase: PhaseID

    var body: some View {
        let (s, e) = state.tour.window(phase)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FulbrightHeader(title: "Phase \(phase.rawValue): \(phase.title)",
                                subtitle: "\(s.formatted(date: .abbreviated, time: .omitted)) – \(e.formatted(date: .abbreviated, time: .omitted)) · \(phase.summary)",
                                systemImage: phase.systemImage)
                TaskChecklist(phase: phase)
                switch phase {
                case .setup: SetupTools()
                case .outreach: HostsTools()
                case .program: ProgramTools()
                case .registration: RegistrationTools()
                case .submissions: SubmissionTools()
                case .tour: TourDayTools()
                case .wrapup: WrapUpTools()
                }
            }
            .padding(.bottom, 60)
        }
    }
}

struct TaskChecklist: View {
    @Environment(AppState.self) private var state
    let phase: PhaseID
    @State private var newTitle = ""

    var body: some View {
        let items = state.tour.tasks.filter { $0.phase == phase }.sorted { state.tour.dueDate($0) < state.tour.dueDate($1) }
        Card(title: "Checklist") {
            if state.checklistInSalesforce && state.tour.tasks.isEmpty {
                HStack {
                    Text("This program has no checklist yet.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Create default checklist") { state.createDefaultChecklistAction() }.glassButton()
                }
            }
            ForEach(items) { task in
                HStack {
                    Toggle("", isOn: Binding(get: { task.done }, set: { var t = task; t.done = $0; state.updateTask(t) })).labelsHidden()
                    TextField("Task", text: Binding(get: { task.title }, set: { v in
                        if let i = state.tour.tasks.firstIndex(where: { $0.id == task.id }) { state.tour.tasks[i].title = v }
                    }))
                    .textFieldStyle(.plain).strikethrough(task.done)
                    .onSubmit { if let t = state.tour.tasks.first(where: { $0.id == task.id }) { state.updateTask(t) } }
                    Spacer()
                    if state.checklistInSalesforce {
                        Picker("", selection: Binding(get: { task.ownerId ?? "" }, set: { var t = task; t.ownerId = $0; state.updateTask(t) })) {
                            if task.ownerId == nil { Text("—").tag("") }
                            ForEach(state.users, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 160)
                    }
                    let due = state.tour.dueDate(task)
                    DatePicker("", selection: Binding(get: { due }, set: { var t = task; t.dueDate = $0; state.updateTask(t) }), displayedComponents: .date)
                        .labelsHidden().frame(width: 110)
                        .foregroundStyle(!task.done && due < Calendar.current.startOfDay(for: Date()) ? Theme.alertOnDark : .primary)
                    if let sf = task.salesforceId, let u = state.salesforce.recordURL(sf) {
                        Link(destination: u) { Image(systemName: "arrow.up.right.square") }.help("Open in the database")
                    }
                    Button { state.deleteTask(task) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Add task…", text: $newTitle).onSubmit(add)
                Button("Add", action: add).disabled(newTitle.isEmpty)
            }
            if !state.checklistInSalesforce {
                Text(state.tour.campaignId.isEmpty ? "Local checklist — select a program to work with the team's shared checklist."
                     : "Local checklist — the checklist phase field is not deployed in the database yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func add() {
        state.addTask(phase: phase, title: newTitle)
        newTitle = ""
    }
}

// MARK: - 0 Setup

struct SetupTools: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let i = state.tourIndex
        Card(title: "Tour") {
            Form {
                TextField("Program name (renames the program for the whole team)", text: $state.data.tours[i].name)
                    .disabled(state.tour.campaignId.isEmpty)
                TextField("City / region", text: $state.data.tours[i].city)
                DatePicker("Start", selection: $state.data.tours[i].startDate, displayedComponents: .date)
                DatePicker("End", selection: $state.data.tours[i].endDate, in: state.tour.startDate..., displayedComponents: .date)
            }
            .onChange(of: state.tour) { state.save() }
        }
        Card(title: "Program (shared with the team)") {
            HStack {
                Text(state.tour.campaignName.isEmpty ? "No program selected — choose one in the sidebar" : state.tour.campaignName)
                Spacer()
                if !state.tour.campaignId.isEmpty, let u = state.salesforce.recordURL(state.tour.campaignId) { Link("Open in the database", destination: u) }
            }
            Text("Name, dates, city, Drive folder and agenda are fields of the program; the checklist is stored as Tasks and the host visits as Opportunities — the whole team works on the same data. Status: \(state.syncStatus)")
                .font(.caption).foregroundStyle(.secondary)
            if !state.storageMissingFields.isEmpty {
                Label("Not deployed yet: \(state.storageMissingFields.joined(separator: ", ")) — deploy the metadata package (salesforce/METADATA-REVIEW.md).",
                      systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warnOnDark)
            }
            if !state.tour.programs.isEmpty {
                Text("Additional programs").font(.subheadline.bold())
                ForEach(state.tour.programs) { p in
                    HStack { Text(p.name); Text(p.purpose).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let u = state.salesforce.recordURL(p.id) { Link("Open", destination: u) } }
                }
            }
            if !state.salesforceConnected { Text("Connect the database in Settings first.").font(.caption).foregroundStyle(.secondary) }
        }
        Card(title: "Google Drive") {
            Text("Each study tour has its own folder in the shared study tours folder, named like the program, with a copy of the agenda template. Both links are stored on the program.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if state.tour.driveFolderId.isEmpty { Text("No folder yet") }
                else if let u = URL(string: DriveStructure.folderURL(state.tour.driveFolderId)) { Link("Open tour folder", destination: u) }
                if !state.tour.agendaDocId.isEmpty, let u = URL(string: DriveStructure.slidesURL(state.tour.agendaDocId)) { Link("Open agenda", destination: u) }
                Spacer()
                Button("Create folder & agenda") { state.createDriveFolder() }
                    .disabled(!state.googleConnected || !state.salesforceConnected || state.tour.campaignId.isEmpty || !state.tour.driveFolderId.isEmpty)
            }
        }
    }
}


// MARK: - 1 Hosts

struct HostsTools: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Card(title: "Host institutions (Opportunities on this program)") {
            HStack {
                Text("Stages: Qualification = identified · Needs Analysis = letter sent · Proposal/Negotiation = in discussion · Closed Won = confirmed · Closed Lost = declined")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reload") { state.loadHostVisits() }.disabled(!state.salesforceConnected || state.tour.campaignId.isEmpty)
            }
            if state.hostVisits.isEmpty {
                Text(state.tour.campaignId.isEmpty ? "Select the program first." : "No host visits linked to this program yet — create them in the database (with this program selected on the visit).")
                    .foregroundStyle(.secondary)
            }
            ForEach(state.hostVisits) { v in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.organization.isEmpty ? v.name : v.organization).bold()
                        Text(v.visitStart.map { $0.formatted(date: .abbreviated, time: .shortened) + (v.visitEnd.map { " – " + $0.formatted(date: .omitted, time: .shortened) } ?? "") } ?? "Visit time not set")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(v.statusLabel).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 2)
                        .background((v.isConfirmed ? Color.green : v.isDeclined ? Theme.usRed : Theme.fbMid).opacity(0.75), in: Capsule())
                    if let u = state.salesforce.recordURL(v.id) { Link("Open", destination: u).font(.caption) }
                }
            }
        }
        .task(id: state.tour.campaignId) { if state.hostVisits.isEmpty && state.salesforceConnected { state.loadHostVisits() } }
    }
}

struct OptionalDatePicker: View {
    let label: String
    @Binding var date: Date?
    var body: some View {
        HStack {
            Toggle(label, isOn: Binding(get: { date != nil }, set: { date = $0 ? (date ?? Date()) : nil }))
            if date != nil {
                DatePicker("", selection: Binding(get: { date ?? Date() }, set: { date = $0 }), displayedComponents: .date).labelsHidden()
            }
        }
    }
}

// MARK: - 2 Program

struct ProgramTools: View {
    @Environment(AppState.self) private var state
    @State private var newLink = ""

    var body: some View {
        @Bindable var state = state
        Card(title: "Agenda") {
            HStack {
                Text("\(state.tour.agenda.count) items in the calendar.")
                if !state.tour.agendaDocId.isEmpty, let u = GoogleClient.fileURL(state.tour.agendaDocId) { Link("Open agenda document", destination: u) }
                Spacer()
                Button("Edit agenda") { state.selection = .agenda }
            }
        }
        KnowledgeBaseCard()
        Card(title: "Documents & links (flyer, marketing, registration form)") {
            ForEach(state.tour.links, id: \.self) { l in
                HStack { if let u = URL(string: l) { Link(l, destination: u) } else { Text(l) }
                    Spacer(); Button { state.tour.links.removeAll { $0 == l } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless) }
            }
            HStack { TextField("https://…", text: $newLink); Button("Add") { state.tour.links.append(newLink); newLink = "" }.disabled(newLink.isEmpty) }
        }
    }
}

// MARK: - 3 Registration & data quality

struct RegistrationTools: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Card(title: "Members of the tour program") {
            HStack {
                Button("Load members") { state.loadParticipants() }.disabled(!state.salesforceConnected)
                Button("Run cleansing & passport check") { state.runCleansing() }.disabled(state.participants.isEmpty)
                Spacer()
                Text("\(state.participants.count) members").foregroundStyle(.secondary)
            }
            Text("Member data, including passport fields, is held in memory only and never saved on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let report = state.report {
            Card(title: "Proposed corrections (\(report.changes.count))") {
                if report.changes.isEmpty { Text("No formatting issues found.").foregroundStyle(.secondary) }
                else {
                    HStack {
                        Button("Select all") { state.selectedChanges = Set(report.changes.map(\.id)) }
                        Button("Select none") { state.selectedChanges = [] }
                        Spacer()
                        Button("Save \(state.selectedChanges.count) corrections") { state.applySelectedChanges() }
                            .buttonStyle(.borderedProminent).tint(Theme.fbBlue).disabled(state.selectedChanges.isEmpty)
                    }
                    Table(report.changes) {
                        TableColumn("") { c in
                            Toggle("", isOn: Binding(get: { state.selectedChanges.contains(c.id) },
                                                     set: { if $0 { state.selectedChanges.insert(c.id) } else { state.selectedChanges.remove(c.id) } })).labelsHidden()
                        }.width(24)
                        TableColumn("Member") { Text($0.participantName) }
                        TableColumn("Field") { Text($0.field.label) }
                        TableColumn("Current") { c in Text(c.field.isPassportData && c.field == .passportNumber ? mask(c.oldValue) : c.oldValue) }
                        TableColumn("New") { c in Text(c.field == .passportNumber ? mask(c.newValue) : c.newValue).foregroundStyle(Theme.skyOnDark) }
                        TableColumn("Why") { Text($0.reason).foregroundStyle(.secondary) }
                    }
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 220)
                }
            }
            Card(title: "Issues (\(report.issues.count))") {
                if report.issues.isEmpty { Label("No issues — ready for host submissions.", systemImage: "checkmark.seal").foregroundStyle(.green) }
                ForEach(report.issues) { issue in
                    HStack(alignment: .top) {
                        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(issue.severity == .error ? Theme.alertOnDark : issue.severity == .warning ? Theme.warnOnDark : .secondary)
                        Text(issue.participantName).bold().frame(width: 170, alignment: .leading)
                        Text(issue.message)
                        Spacer()
                        if let u = state.salesforce.recordURL(issue.participantId) { Link("Open", destination: u).font(.caption) }
                    }
                }
            }
        }
    }

    private func mask(_ s: String) -> String { s.count <= 3 ? s : String(repeating: "•", count: s.count - 3) + s.suffix(3) }
}

// MARK: - 4 Submissions & logistics

struct SubmissionTools: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Card(title: "Attendee lists for host organizations") {
            Text("For each confirmed visit: the host's Excel form attached to the Opportunity is filled with the attending members, reviewed here and sent via Gmail to the Opportunity's “Attendee List Recipient”. Gemini only sees the form's headers — never member data.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("\(state.participants.count) attending members loaded").font(.caption)
                Spacer()
                Button("Reload members") { state.loadParticipants() }.disabled(!state.salesforceConnected)
                Button("Reload visits") { state.loadHostVisits() }.disabled(!state.salesforceConnected)
            }
        }
        ForEach(state.hostVisits.filter { !$0.isDeclined }) { v in HostListCard(visit: v) }
        Card(title: "Logistics headcount") {
            let n = state.participants.count
            LabeledContent("Attending members", value: "\(n)")
            let diets = Dictionary(grouping: state.participants.map { $0[.dietary].trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, by: { $0.lowercased() })
            ForEach(diets.keys.sorted(), id: \.self) { k in LabeledContent(diets[k]!.first!, value: "\(diets[k]!.count)") }
        }
        .task(id: state.tour.campaignId) { if state.hostVisits.isEmpty && state.salesforceConnected { state.loadHostVisits() } }
    }
}

struct HostListCard: View {
    @Environment(AppState.self) private var state
    let visit: HostVisit
    @State private var confirmSend = false
    @State private var showIds = false

    var body: some View {
        let draft = state.hostListDrafts[visit.id]
        Card(title: visit.organization.isEmpty ? visit.name : visit.organization) {
            HStack {
                Text(visit.statusLabel).font(.caption.bold())
                if let s = visit.visitStart { Text("Visit \(s.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                if let d = visit.listDeadline {
                    Text("List due \(d.formatted(date: .abbreviated, time: .omitted))").font(.caption.bold())
                        .foregroundStyle(d < Date() && draft?.sentAt == nil ? Theme.alertOnDark : .secondary)
                }
                Spacer()
                if let u = state.salesforce.recordURL(visit.id) { Link("Opportunity", destination: u).font(.caption) }
            }
            HStack {
                Image(systemName: visit.recipientEmail.isEmpty ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle")
                Text(visit.recipientEmail.isEmpty ? "No attendee list recipient set on the Opportunity" : "\(visit.recipientName) <\(visit.recipientEmail)>")
                    .foregroundStyle(visit.recipientEmail.isEmpty ? Theme.warnOnDark : .primary)
                Spacer()
                Button(draft == nil ? "Prepare list" : "Prepare again") { state.prepareHostList(visit) }
                    .glassButton()
                    .disabled(!state.salesforceConnected || state.tour.campaignId.isEmpty)
            }
            if let d = draft {
                Divider()
                Text("Form “\(d.file.title)” · sheet “\(d.template.sheetName)” · header row \(d.mapping.headerRow), \(d.participantCount) members from row \(d.mapping.firstDataRow) · columns mapped by \(d.mappingSource)")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(d.mapping.columns) { c in
                    HStack {
                        Text(c.column).font(.caption.monospaced()).frame(width: 26, alignment: .leading)
                        Text(c.header).frame(width: 230, alignment: .leading).lineLimit(1)
                        Picker("", selection: Binding(get: { c.source }, set: { state.updateMapping(visit.id, column: c.column, source: $0) })) {
                            ForEach(Array(ColumnSource.allChoices.enumerated()), id: \.offset) { _, src in Text(src.label).tag(src) }
                            if case .constant = c.source { Text(c.source.label).tag(c.source) }
                        }
                        .labelsHidden().frame(width: 200)
                        if c.countryFormat == .iso3 { Text("ISO3").font(.caption2).padding(3).background(.quaternary, in: Capsule()) }
                        if !c.allowedValues.isEmpty { Text("dropdown").font(.caption2).padding(3).background(.quaternary, in: Capsule()) }
                        Spacer()
                        if let p = state.participants.sorted(by: { $0[.lastName] < $1[.lastName] }).first {
                            let sample = XLSXTemplate.cellText(c, participant: p, index: 1, dateFormat: d.mapping.dateFormat)
                            Text(c.source == .field(.passportNumber) && !showIds ? String(repeating: "•", count: max(0, sample.count - 3)) + sample.suffix(3) : sample)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                ForEach(d.missing, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warnOnDark).font(.caption) }
                HStack {
                    Toggle("Show ID numbers in preview", isOn: $showIds).font(.caption)
                    Spacer()
                    if let url = d.localURL { Button("Open filled form in Excel") { NSWorkspace.shared.open(url) } }
                }
                TextField("Subject", text: Binding(get: { d.subject }, set: { state.hostListDrafts[visit.id]?.subject = $0 }))
                TextEditor(text: Binding(get: { d.body }, set: { state.hostListDrafts[visit.id]?.body = $0 }))
                    .frame(height: 140).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                HStack {
                    if let sent = d.sentAt { Label("Sent \(sent.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    Spacer()
                    Button("Send to \(visit.recipientName.isEmpty ? "recipient" : visit.recipientName)") { confirmSend = true }
                        .glassButton(prominent: true)
                        .disabled(visit.recipientEmail.isEmpty || d.filled == nil || !state.googleConnected)
                }
            }
        }
        .confirmationDialog("Send the attendee list (\(draft?.participantCount ?? 0) members, incl. ID data) to \(visit.recipientEmail)?", isPresented: $confirmSend) {
            Button("Send via Gmail") { state.sendHostList(visit.id) }
        } message: { Text("The email is logged on the recipient and the Opportunity; each member gets a data-disclosure record.") }
    }
}

// MARK: - 5 Tour days

struct TourDayTools: View {
    @Environment(AppState.self) private var state
    var body: some View {
        Card(title: "Lists for the road") {
            Text("Attendance sheet per day for the attending members.").font(.caption).foregroundStyle(.secondary)
            Button("Export attendance list") { state.exportTourLists() }.disabled(state.participants.isEmpty)
        }
        Card(title: "Today") {
            let today = state.tour.agenda.filter { Calendar.current.isDateInToday($0.start) }
            if today.isEmpty { Text("No agenda items today.").foregroundStyle(.secondary) }
            ForEach(today) { i in HStack { Text(i.start.formatted(date: .omitted, time: .shortened)).frame(width: 60); Text(i.title).bold(); Text(i.location).foregroundStyle(.secondary) } }
            Button("Post today's plan to the team chat…") {
                let lines = today.map { "• \($0.start.formatted(date: .omitted, time: .shortened)) \($0.title) – \($0.location)" }
                state.shareToTeam("*\(state.tour.name) – today*\n" + lines.joined(separator: "\n"))
            }.disabled(today.isEmpty)
        }
    }
}

// MARK: - 6 Wrap-up & data protection

struct WrapUpTools: View {
    @Environment(AppState.self) private var state
    @State private var confirmSF = false
    @State private var confirmFiles = false

    var body: some View {
        ThankYouTools()
        if state.isSalesforceAdmin { OrgWideScrub() }
        Card(title: "Scrub passport data — this program") {
            Text("Clears the personal data below on every member of this tour's program (\(state.tour.campaignName)) in the database — whatever their attendance status, including cancelled — and deletes every exported list (on this Mac and in Google Drive). Each step is written to the audit log below.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Fields: " + ParticipantField.defaultScrub.map(\.label).joined(separator: ", "))
                .font(.callout.bold())
            HStack {
                Button("Clear fields in the database…") { confirmSF = true }
                    .buttonStyle(.borderedProminent).tint(Theme.usRed)
                    .disabled(!state.salesforceConnected)
                Button("Delete all exported files…") { confirmFiles = true }.tint(Theme.usRed)
            }
        }
        .confirmationDialog("Permanently clear \(ParticipantField.defaultScrub.count) fields on all members of \(state.tour.campaignName)?", isPresented: $confirmSF) {
            Button("Clear in the database", role: .destructive) { state.scrubSalesforce() }
        } message: { Text("This cannot be undone from the app.") }
        .confirmationDialog("Permanently delete all exported participant lists (local and Google Drive)?", isPresented: $confirmFiles) {
            Button("Delete files", role: .destructive) { state.deleteExports() }
        }
        Card(title: "Data-protection audit log") {
            if state.tour.scrubLog.isEmpty { Text("Nothing deleted yet.").foregroundStyle(.secondary) }
            ForEach(state.tour.scrubLog) { e in
                HStack { Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).frame(width: 150, alignment: .leading); Text(e.action).bold(); Text("(\(e.count))"); Text(e.detail).foregroundStyle(.secondary) }
            }
        }
    }
}

struct ThankYouTools: View {
    @Environment(AppState.self) private var state
    @State private var drafts: [String: String] = [:]
    @State private var subject = "Thank you for hosting the Fulbright study tour"

    var body: some View {
        Card(title: "Thank-you emails to officials") {
            HStack {
                if let p = state.tour.programs.first(where: { $0.purpose.contains("Thank") }) {
                    Label("Program: \(p.name)", systemImage: "checkmark.circle")
                } else {
                    Button("Create thank-you program") { state.createThankYouProgram() }.disabled(!state.salesforceConnected)
                }
                Spacer()
            }
            TextField("Subject", text: $subject)
            // confirmed visits (Opportunities) → their attendee-list recipient; logged on the Opportunity
            ForEach(state.hostVisits.filter { $0.isConfirmed && !$0.recipientEmail.isEmpty }.map { v -> (Host, HostContact) in
                var h = Host(name: v.organization.isEmpty ? v.name : v.organization, accountId: v.id)
                h.visitDate = v.visitStart
                return (h, HostContact(id: v.recipientId ?? "", name: v.recipientName, email: v.recipientEmail, title: ""))
            }, id: \.1.email) { h, c in
                do {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("\(c.name) — \(h.name)").bold()
                            Spacer()
                            Button("Draft with Gemini") {
                                state.run("Drafting…") { drafts[c.id] = try await state.draftThankYou(host: h, contact: c) }
                            }.disabled(!state.gemini.isConfigured)
                            Button("Send via Gmail") { state.sendThankYou(host: h, contact: c, subject: subject, body: drafts[c.id] ?? "") }
                                .disabled((drafts[c.id] ?? "").isEmpty)
                        }
                        if drafts[c.id] != nil {
                            TextEditor(text: Binding(get: { drafts[c.id] ?? "" }, set: { drafts[c.id] = $0 })).frame(height: 110)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                        }
                    }
                }
            }
            Text("Officials are never emailed automatically — each thank-you is reviewed and sent individually.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Admin-only: delete passport data on every member (Lead) in the org.
struct OrgWideScrub: View {
    @Environment(AppState.self) private var state
    private let fields = ParticipantField.defaultScrub
    @State private var confirmText = ""
    private let phrase = "DELETE ALL PASSPORT DATA"

    var body: some View {
        Card(title: "Administrator: delete passport data across the whole database") {
            Label("Visible because you are a database administrator (“Modify All Data”).", systemImage: "person.badge.key").font(.caption)
            Text("Clears \(fields.map(\.label).sorted().joined(separator: ", ")) on **every member in the database**, regardless of program. Converted members are read-only in the database and will be reported, not changed.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Type \(phrase) to confirm", text: $confirmText)
                Button("Delete org-wide") { state.scrubOrgWide(); confirmText = "" }
                    .buttonStyle(.borderedProminent).tint(Theme.usRed)
                    .disabled(confirmText != phrase || fields.isEmpty)
            }
        }
    }
}

/// The Google Doc with confirmed facts the email assistant may use (shared across tours by default).
struct KnowledgeBaseCard: View {
    @Environment(AppState.self) private var state
    @State private var editing = false
    @State private var url = ""

    var body: some View {
        Card(title: "Knowledge base for the email assistant") {
            Text("Confirmed facts (meeting points, dress code, documents, costs …) the assistant may use when answering attendees. By default all programs share one document; a program can point to its own.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if let u = URL(string: state.knowledgeBaseURL) { Link("Open knowledge base document", destination: u) }
                if state.knowledgeBaseURL != KnowledgeBase.defaultURL { Text("program-specific").font(.caption2).padding(3).background(.quaternary, in: Capsule()) }
                Spacer()
                Button("Reload") { Task { _ = await state.knowledgeBaseText(force: true) } }.disabled(!state.googleConnected)
                Button(editing ? "Cancel" : "Change…") { url = state.knowledgeBaseURL; editing.toggle() }
                    .disabled(!state.salesforceConnected || state.tour.campaignId.isEmpty)
            }
            if editing {
                HStack {
                    TextField("https://docs.google.com/document/d/…", text: $url)
                    Button("Use shared default") { url = KnowledgeBase.defaultURL }
                    Button("Save to program") { state.setKnowledgeBase(url: url); editing = false }
                }
            }
            Text(state.knowledgeBaseStatus).font(.caption).foregroundStyle(.secondary)
        }
        .task(id: state.tour.campaignId) { _ = await state.knowledgeBaseText() }
    }
}
