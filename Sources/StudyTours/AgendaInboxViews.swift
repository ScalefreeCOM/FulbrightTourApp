import SwiftUI
import AppKit
import StudyToursCore

// MARK: - Agenda & calendar

struct AgendaView: View {
    @Environment(AppState.self) private var state
    @State private var editing: AgendaItem?

    var body: some View {
        let tour = state.tour
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FulbrightHeader(title: "Agenda & Calendar",
                                subtitle: "One agenda → Salesforce Events · Google Calendar (team invites) · agenda Google Doc",
                                systemImage: "calendar")
                Card {
                    HStack {
                        Button { editing = AgendaItem(title: "", kind: .visit, start: tour.startDate.addingTimeInterval(9 * 3600),
                                                      end: tour.startDate.addingTimeInterval(11 * 3600)) } label: { Label("New item", systemImage: "plus") }
                        Spacer()
                        TextField("Google Calendar ID", text: Binding(get: { state.tour.googleCalendarId }, set: { state.tour.googleCalendarId = $0 }))
                            .frame(width: 220).help("“primary” or the ID of a shared tour calendar")
                        if !tour.agendaDocId.isEmpty, let u = GoogleClient.fileURL(tour.agendaDocId) { Link("Agenda doc", destination: u) }
                        Button { state.syncAgenda() } label: { Label("Sync now (\(tour.agenda.filter(\.needsSync).count) pending)", systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.borderedProminent).tint(Theme.fbBlue)
                            .disabled(!state.salesforceConnected && !state.googleConnected)
                        Button { state.shareToTeam(agendaText()) } label: { Image(systemName: "bubble.left.and.bubble.right") }.help("Post the agenda to the team chat (you review it before sending)")
                    }
                }
                let byDay = Dictionary(grouping: tour.agenda) { Calendar.current.startOfDay(for: $0.start) }
                ForEach(byDay.keys.sorted(), id: \.self) { day in
                    Card(title: day.formatted(date: .complete, time: .omitted)) {
                        ForEach(byDay[day]!.sorted { $0.start < $1.start }) { item in
                            HStack {
                                Text("\(item.start.formatted(date: .omitted, time: .shortened))–\(item.end.formatted(date: .omitted, time: .shortened))")
                                    .font(.callout.monospacedDigit()).frame(width: 120, alignment: .leading)
                                Image(systemName: icon(item.kind)).foregroundStyle(Theme.skyOnDark)
                                VStack(alignment: .leading) {
                                    Text(item.title).bold()
                                    if !item.location.isEmpty { Text(item.location).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if !item.publicItem { Text("internal").font(.caption2).padding(3).background(.quaternary, in: Capsule()) }
                                syncBadge(item.salesforceEventId != nil, "SF")
                                syncBadge(item.googleEventId != nil, "G")
                                if item.needsSync { Image(systemName: "circle.dotted").foregroundStyle(.orange).help("Not yet synced") }
                                Button("Edit") { editing = item }
                            }
                        }
                    }
                }
                if tour.agenda.isEmpty { Card { Text("No agenda items yet. Add host visits, meals, the city tour and team meetings.").foregroundStyle(.secondary) } }
            }
            .padding(.bottom, 60)
        }
        .sheet(item: $editing) { item in AgendaEditor(item: item) }
    }

    private func syncBadge(_ on: Bool, _ s: String) -> some View {
        Text(s).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2)
            .background(on ? Theme.fbCyan.opacity(0.25) : Color.gray.opacity(0.15), in: Capsule())
    }

    private func icon(_ k: AgendaKind) -> String {
        switch k {
        case .visit: return "building.columns"
        case .meal: return "fork.knife"
        case .cityTour: return "figure.walk"
        case .travel: return "tram"
        case .teamMeeting: return "person.3"
        case .other: return "star"
        }
    }

    private func agendaText() -> String {
        "*\(state.tour.name) – agenda*\n" + state.tour.agenda.filter(\.publicItem).map {
            "• \($0.start.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute())) \($0.title)\($0.location.isEmpty ? "" : " – \($0.location)")"
        }.joined(separator: "\n")
    }
}

struct AgendaEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var item: AgendaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title.isEmpty ? "New agenda item" : item.title).font(.title2.bold()).foregroundStyle(.primary)
            Form {
                TextField("Title", text: $item.title)
                Picker("Type", selection: $item.kind) { ForEach(AgendaKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                DatePicker("Start", selection: $item.start)
                DatePicker("End", selection: $item.end, in: item.start...)
                TextField("Location", text: $item.location)
                Picker("Host", selection: $item.hostId) {
                    Text("—").tag(UUID?.none)
                    ForEach(state.tour.hosts) { Text($0.name).tag(Optional($0.id)) }
                }
                Toggle("Show in participant agenda document", isOn: $item.publicItem)
                TextField("Details", text: $item.details, axis: .vertical).lineLimit(3...8)
            }
            HStack {
                if state.tour.agenda.contains(where: { $0.id == item.id }) {
                    Button("Delete", role: .destructive) { state.deleteAgenda(item); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if item.kind == .visit, item.location.isEmpty, let h = state.tour.hosts.first(where: { $0.id == item.hostId }) { item.location = h.name }
                    state.touchAgenda(item); dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(item.title.isEmpty)
            }
        }
        .padding(20).frame(width: 520)
    }
}

// MARK: - Inbox

struct InboxView: View {
    @Environment(AppState.self) private var state
    @State private var selected: String?
    @State private var importantOnly = false
    @AppStorage("inboxUnreadOnly") private var unreadOnly = true

    var body: some View {
        // officials are answered in Gmail directly — they appear in "At a Glance" only
        let items = state.inbox.filter {
            $0.identity.kind != .official && $0.identity.kind != .team && (!importantOnly || $0.important)
                && (!unreadOnly || $0.message.labelIds.contains("UNREAD"))
        }
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Button { state.refreshInbox() } label: { Label("Scan", systemImage: "arrow.clockwise") }.disabled(!state.googleConnected)
                    Toggle("Unread only", isOn: $unreadOnly).toggleStyle(.switch).controlSize(.small)
                        .help("Show only mails that are unread in Gmail")
                    Toggle("Important only", isOn: $importantOnly).toggleStyle(.switch).controlSize(.small)
                    Spacer()
                    if state.settings.assistant.autoSend { Label("Auto-reply on", systemImage: "bolt.fill").font(.caption).foregroundStyle(Theme.skyOnDark) }
                }
                .padding(10)
                List(items, selection: $selected) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.important ? "star.fill" : "circle").foregroundStyle(item.important ? Theme.alertOnDark : .secondary).font(.caption)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                if item.identity.record?.vip == true { VIPBadge() }
                                Text(item.message.fromName).bold().lineLimit(1)
                                Spacer()
                                Text(item.message.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(item.message.subject).lineLimit(1)
                            HStack(spacing: 6) {
                                tag(item.identity.kind.rawValue, item.identity.kind == .official ? Theme.usRed : item.identity.kind == .attendee ? Theme.fbMid : .gray)
                                if item.proposal != nil { tag("New?", .orange) }
                                if item.answered { tag("Answered", .green) }
                                if item.logged { tag("Logged", .gray) }
                            }
                        }
                    }
                    .tag(item.id)
                }
                .scrollContentBackground(.hidden)
                if !state.googleConnected { Text("Connect Google in Settings to scan the Fulbright mailbox.").font(.caption).padding() }
            }
            .frame(minWidth: 260, idealWidth: 330)
            .glassPanel(cornerRadius: 22)
            .padding(.trailing, 6)

            Group {
                if let id = selected, state.inbox.contains(where: { $0.id == id }) { MessageDetail(itemId: id) }
                else { ContentUnavailableView("Select a message", systemImage: "envelope.open") }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            .glassPanel(cornerRadius: 22)
            .padding(.leading, 6)
        }
        // new member/contact: reviewed in a pop-up in front of everything
        .sheet(isPresented: Binding(get: { state.reviewingProposal != nil }, set: { if !$0 { state.reviewingProposal = nil } })) {
            if let id = state.reviewingProposal, let p = state.inbox.first(where: { $0.id == id })?.proposal {
                ProposalSheet(itemId: id, proposal: p)
            }
        }
    }

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 1).background(c.opacity(0.75), in: Capsule()).foregroundStyle(.white)
    }
}

struct MessageDetail: View {
    @Environment(AppState.self) private var state
    let itemId: String
    @State private var confirmSend = false

    var body: some View {
        @Bindable var state = state
        let i = state.inbox.firstIndex { $0.id == itemId }!
        let item = state.inbox[i]
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if item.identity.record?.vip == true { VIPBadge(withLabel: true) }
                        Text(item.message.subject).font(.title3.bold())
                    }
                    Text("\(item.message.from) · \(item.message.date.formatted())").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Text("Sender: \(item.identity.kind.rawValue) (\(item.identity.source))").font(.caption)
                        if let r = item.identity.record, let u = state.salesforce.recordURL(r.id) { Link("Open in Salesforce", destination: u).font(.caption) }
                    }
                }
                if let t = item.triage {
                    Card(title: "Assessment") {
                        Text("\(t.relatedToTour ? "Study tour" : "Not tour-related") · importance \(t.importance) · \(t.topic)")
                        Text(t.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if item.identity.kind == .official {
                    Label("Official or assistant of a host — please reply personally. The assistant never answers officials.", systemImage: "building.columns.fill")
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.usRed.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                if let p = item.proposal {
                    HStack {
                        Label("Not in Salesforce — suggested: new \(p.kind == .lead ? "member" : "contact") \(p.firstName) \(p.lastName)\(p.vip ? " (VIP)" : "")",
                              systemImage: "person.crop.circle.badge.plus")
                        Spacer()
                        Button("Review…") { state.reviewingProposal = itemId }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }
                else if item.identity.kind == .unknown {
                    HStack {
                        Label("This sender is not in Salesforce.", systemImage: "person.crop.circle.badge.questionmark")
                        Spacer()
                        Button("Add sender to Salesforce…") { state.proposeRecord(itemId) }
                            .disabled(!state.salesforceConnected)
                            .help("Review name, organization and record type before anything is created")
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }

                Card(title: "Message") { Text(item.message.body.isEmpty ? item.message.snippet : item.message.body).textSelection(.enabled) }

                if item.identity.kind == .attendee || (item.identity.kind == .unknown && item.triage?.senderType == "attendee") {
                    Card(title: "Reply (sent via Gmail, logged on the member in Salesforce)") {
                        if item.draft == nil {
                            Button("Draft reply with Gemini") { state.draftReply(itemId) }.disabled(!state.gemini.isConfigured)
                        } else {
                            if let missing = item.draft?.missingInfo, !missing.isEmpty {
                                Label("Missing: " + missing.joined(separator: "; "), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                            TextEditor(text: $state.inbox[i].draftBody).frame(minHeight: 180)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                            HStack {
                                Text(item.status).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Re-draft") { state.draftReply(itemId) }
                                Button("Send via Gmail") { confirmSend = true }
                                    .buttonStyle(.borderedProminent).tint(Theme.fbBlue)
                                    .disabled(item.answered || item.draftBody.contains("[CHECK") || item.identity.record == nil)
                            }
                            if item.identity.record == nil { Text("Create the member record first so the email is logged.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .padding(18)
        }
        .confirmationDialog("Send this reply to \(item.message.fromAddress) via Gmail?", isPresented: $confirmSend) {
            Button("Send") { state.sendManually(itemId) }
        }
    }
}

struct ProposalSheet: View {
    @Environment(AppState.self) private var state
    let itemId: String
    @State var proposal: RecordProposal

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to Salesforce").font(.title2.bold())
            Text("\(proposal.email) is not in Salesforce yet. Check the details, then create the record.")
                .foregroundStyle(.secondary)
            Picker("Type", selection: $proposal.kind) {
                Text("Member — attendee").tag(RecordProposal.Kind.lead)
                Text("Contact + organization — official/assistant").tag(RecordProposal.Kind.contact)
            }.pickerStyle(.segmented).labelsHidden()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow { Text("First name"); TextField("First name", text: $proposal.firstName) }
                GridRow { Text("Last name"); TextField("Last name (required)", text: $proposal.lastName) }
                GridRow { Text("Organization"); TextField("Organization", text: $proposal.organization) }
                GridRow { Text("Job title"); TextField("Job title", text: $proposal.jobTitle) }
                if proposal.kind == .contact {
                    GridRow { Text("Greeting"); TextField("e.g. Dear Jane:", text: $proposal.greeting) }
                }
            }
            .textFieldStyle(.roundedBorder)
            if proposal.kind == .contact {
                Toggle(isOn: $proposal.vip) {
                    HStack(spacing: 6) { VIPBadge(); Text("VIP — holds an official role or is the person the group visits (not an assistant)") }
                }
                Text(proposal.existingAccount.map { "Will be added to the existing organization “\($0.name)”." } ?? "A new organization “\(proposal.organization)” will be created.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("The member is added to the selected program.").font(.callout).foregroundStyle(.secondary)
            }
            if !proposal.possibleDuplicates.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Same name already exists — check before creating:", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    ForEach(proposal.possibleDuplicates) { d in
                        HStack { Text("\(d.kind.displayName.capitalized): \(d.name) <\(d.email)>"); if let u = state.salesforce.recordURL(d.id) { Link("Open", destination: u) } }.font(.caption)
                    }
                }
            }
            Text("Right before creating, the app checks Salesforce again by email, so no duplicates are written.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Don't add") {
                    if let i = state.inbox.firstIndex(where: { $0.id == itemId }) { state.inbox[i].proposal = nil }
                    state.reviewingProposal = nil
                }
                .help("Discard this suggestion")
                Spacer()
                Button("Cancel", role: .cancel) { state.reviewingProposal = nil }.keyboardShortcut(.cancelAction)
                Button("Create in Salesforce") { state.createRecord(itemId, proposal: proposal) }
                    .buttonStyle(.borderedProminent).tint(Theme.fbBlue).keyboardShortcut(.defaultAction)
                    .disabled(proposal.lastName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

/// Marks Contacts flagged as VIP in Salesforce.
struct VIPBadge: View {
    var withLabel = false
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "crown.fill")
            if withLabel { Text("VIP").font(.caption.bold()) }
        }
        .foregroundStyle(Color(red: 0.95, green: 0.75, blue: 0.2))
        .help("VIP in Salesforce — official role or the person visited")
        .accessibilityLabel("VIP")
    }
}
