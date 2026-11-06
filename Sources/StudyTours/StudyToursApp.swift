import SwiftUI
import AppKit
import StudyToursCore

@main
struct StudyToursApp: App {
    @State private var state = AppState()

    init() {
        // Needed when launched via `swift run` (no app bundle): become a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Fulbright Study Tours") {
            ContentView()
                .environment(state)
                .frame(minWidth: 1240, minHeight: 760)
                .preferredColorScheme(.dark)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    Task { await state.refreshMetrics() }
                    if state.salesforceConnected { state.loadPrograms() }
                    Snapshot.runIfRequested(state)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Study Tour…") { state.showNewProgram = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!state.salesforceConnected)
            }
            CommandMenu("Tour") {
                Button("Scan Inbox") { state.refreshInbox() }.keyboardShortcut("r")
                Button("Sync Calendar & Agenda") { state.syncAgenda() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Post Team Status to Chat…") { state.shareToTeam(Assistant.teamDigest(state.tour)) }
            }
        }
        Settings {
            SettingsView().environment(state).frame(width: 720, height: 560).preferredColorScheme(.dark)
        }
    }
}

/// Layout: full-window artwork · glass navigation (left) · content (center) · monitoring (right) · partner footer.
struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Sidebar().frame(width: 250)
                    ZStack(alignment: .bottom) {
                        DetailRouter().frame(maxWidth: .infinity, maxHeight: .infinity)
                        StatusBar()
                    }
                    VStack(spacing: 12) {
                        MonitoringPanel().frame(maxHeight: .infinity)
                        TeamChatPanel().frame(height: 330)
                    }
                    .frame(width: 270)
                }
                PartnerFooter()
            }
            .padding(.horizontal, 12)
            .padding(.top, 34)      // room for the window buttons (hidden title bar)
            .padding(.bottom, 12)
        }
    }
}

struct DetailRouter: View {
    @Environment(AppState.self) private var state
    var body: some View {
        switch state.selection ?? .overview {
        case .overview: OverviewView()
        case .phase(let p): PhaseView(phase: p)
        case .agenda: AgendaView()
        case .inbox: InboxView()
        case .settings: SettingsView().glassPanel(cornerRadius: 22)
        }
    }
}

struct StatusBar: View {
    @Environment(AppState.self) private var state
    var body: some View {
        VStack(spacing: 6) {
            if let b = state.busy {
                HStack { ProgressView().controlSize(.small); Text(b) }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassPanel(cornerRadius: 20)
            }
            if let e = state.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.alertOnDark)
                    Text(e).lineLimit(3).textSelection(.enabled)
                    Button { state.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(10).glassPanel(cornerRadius: 14, tint: Theme.usRed.opacity(0.35))
            }
            if let t = state.toast {
                Label(t, systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassPanel(cornerRadius: 20)
            }
        }
        .padding(.bottom, 14)
        .animation(.default, value: state.busy)
        .animation(.default, value: state.toast)
    }
}

// MARK: - Left: navigation

struct Sidebar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                Text("STUDY TOURS").font(.system(size: 13, weight: .heavy)).kerning(2)
            }
            .padding(.horizontal, 12).padding(.top, 14)

            ProgramSelector().padding(.horizontal, 8).padding(.vertical, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    NavRow(title: "Overview", icon: "house", item: .overview)
                    NavRow(title: "Agenda & Calendar", icon: "calendar", item: .agenda)
                    NavRow(title: "Inbox", icon: "tray.full", item: .inbox,
                           badge: state.inbox.filter { $0.important && !$0.answered && $0.identity.kind == .attendee }.count)

                    Text("PHASES").font(.caption.bold()).kerning(1.5).opacity(0.6)
                        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
                    ForEach(PhaseID.allCases) { p in
                        NavRow(title: p.shortTitle, number: p.rawValue, item: .phase(p), progress: state.tour.progress(p))
                    }
                    Divider().padding(.vertical, 10).padding(.horizontal, 12)
                    NavRow(title: "Settings", icon: "gearshape", item: .settings)
                }
                .padding(.horizontal, 6)
            }
        }
        .foregroundStyle(.white)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassPanel(cornerRadius: 22)
        .sheet(isPresented: Binding(get: { state.showNewProgram }, set: { state.showNewProgram = $0 })) { NewProgramSheet() }
    }
}

/// Links the tour to its Salesforce program (Campaign). Members of that program are the tour's attendees.
struct ProgramSelector: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SALESFORCE PROGRAM").font(.caption2.bold()).kerning(1).opacity(0.6).padding(.horizontal, 4)
            if !state.salesforceConnected {
                Text(state.tourTitle).font(.callout).padding(.horizontal, 4)
                Button { state.selection = .settings } label: {
                    Label("Connect Salesforce…", systemImage: "link").frame(maxWidth: .infinity)
                }
                .glassButton()
            } else {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(
                        get: { state.tour.campaignId },
                        set: { id in state.selectProgram(id: id, name: state.programsInOrg.first { $0.id == id }?.name ?? "") })) {
                        Text(state.programsInOrg.isEmpty ? "Loading programs…" : "Choose program…").tag("")
                        // keep the linked program selectable even if it is no longer active
                        if !state.tour.campaignId.isEmpty, !state.programsInOrg.contains(where: { $0.id == state.tour.campaignId }) {
                            Text(state.tour.campaignName).tag(state.tour.campaignId)
                        }
                        ForEach(state.programsInOrg, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    Button { state.loadPrograms() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Reload programs from Salesforce")
                    if !state.tour.campaignId.isEmpty, let u = state.salesforce.recordURL(state.tour.campaignId) {
                        Link(destination: u) { Image(systemName: "arrow.up.right.square") }.help("Open program in Salesforce")
                    }
                }
                HStack {
                    Image(systemName: state.storageMissingFields.isEmpty ? "icloud.and.arrow.up" : "exclamationmark.icloud")
                    Text(state.storageMissingFields.isEmpty ? state.syncStatus : "Salesforce fields not deployed yet")
                        .lineLimit(1)
                    Spacer()
                    Button("New…") { state.showNewProgram = true }.buttonStyle(.plain).font(.caption.bold())
                        .help("Create a new study tour (program) in Salesforce")
                }
                .font(.caption2).opacity(0.8).padding(.horizontal, 4)
                .help(state.storageMissingFields.isEmpty ? "Tour data lives in Salesforce (program, Tasks, Opportunities) and is shared with the team"
                      : "Deploy the metadata package: " + state.storageMissingFields.joined(separator: ", "))
            }
        }
    }
}

struct NavRow: View {
    @Environment(AppState.self) private var state
    let title: String
    var icon: String? = nil
    var number: Int? = nil
    let item: SidebarItem
    var badge: Int = 0
    var progress: Double? = nil

    var body: some View {
        let selected = (state.selection ?? .overview) == item
        Button { state.selection = item } label: {
            HStack(spacing: 10) {
                if let n = number {
                    Text("\(n)").font(.caption.monospacedDigit().bold())
                        .frame(width: 20, height: 20)
                        .background(Circle().fill((progress ?? 0) >= 1 ? Theme.usRed : .white.opacity(0.18)))
                } else if let icon {
                    Image(systemName: icon).frame(width: 20)
                }
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.usRed))
                }
                if let progress { Text("\(Int(progress * 100))%").font(.caption2).opacity(0.7) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Theme.fbMid.opacity(0.75) : .clear))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Right: monitoring

struct MonitoringPanel: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let tour = state.tour
        let today = Calendar.current.startOfDay(for: Date())
        let overdue = tour.tasks.filter { !$0.done && tour.dueDate($0) < today }.count
        let important = state.inbox.filter { $0.important && !$0.answered && $0.identity.kind != .official }.count
        // VIPs first, then newest
        let officials = state.inbox.filter { $0.identity.kind == .official && $0.message.labelIds.contains("INBOX") }
            .sorted { ($0.identity.record?.vip == true ? 1 : 0, $0.message.date) > ($1.identity.record?.vip == true ? 1 : 0, $1.message.date) }
        let proposals = state.inbox.filter { $0.proposal != nil }.count
        let errors = state.report?.issues.filter { $0.severity == .error }.count
        let passportIssues = state.report?.issues.filter { $0.field?.isPassportData == true }.count
        let confirmed = tour.hosts.filter { $0.status == .confirmed || $0.status == .submitted }.count
        let days = Calendar.current.dateComponents([.day], from: today, to: Calendar.current.startOfDay(for: tour.startDate)).day ?? 0
        let next = tour.agenda.filter { $0.start > Date() }.min { $0.start < $1.start }

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("At a Glance").font(Theme.font(17, .semibold))
                    Spacer()
                    Button { Task { await state.refreshMetrics() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Refresh")
                }
                Metric(icon: "calendar.badge.clock", label: days > 0 ? "Days until tour" : days == 0 ? "Tour starts today" : "Days since start",
                       value: "\(abs(days))", tint: Theme.fbCyan)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                    Metric(icon: "envelope.badge", label: "Unread mails", value: state.unreadCount.map(String.init) ?? "–",
                           tint: Theme.fbMid) { state.selection = .inbox }
                    Metric(icon: "exclamationmark.bubble", label: "Important", value: "\(important)",
                           tint: important > 0 ? Theme.usRed : Theme.fbMid) { state.selection = .inbox }
                    Metric(icon: "person.3", label: "Attendees", value: state.memberCount.map(String.init) ?? (state.participants.isEmpty ? "–" : "\(state.participants.count)"),
                           tint: Theme.fbMid) { state.selection = .phase(.registration) }
                    Metric(icon: "building.columns", label: "Hosts confirmed", value: "\(confirmed)/\(tour.hosts.count)",
                           tint: Theme.fbMid) { state.selection = .phase(.outreach) }
                    Metric(icon: "xmark.octagon", label: "Data errors", value: errors.map(String.init) ?? "–",
                           tint: (errors ?? 0) > 0 ? Theme.usRed : Theme.fbMid) { state.selection = .phase(.registration) }
                    Metric(icon: "person.text.rectangle", label: "Passport issues", value: passportIssues.map(String.init) ?? "–",
                           tint: (passportIssues ?? 0) > 0 ? .orange : Theme.fbMid) { state.selection = .phase(.registration) }
                    Metric(icon: "checklist", label: "Overdue tasks", value: "\(overdue)",
                           tint: overdue > 0 ? Theme.usRed : Theme.fbMid)
                    Metric(icon: "person.badge.plus", label: "New contacts", value: "\(proposals)",
                           tint: proposals > 0 ? .orange : Theme.fbMid) { state.selection = .inbox }
                    Metric(icon: "building.columns.fill", label: "Officials' mails", value: "\(officials.count)",
                           tint: officials.isEmpty ? Theme.fbMid : Theme.usRed)
                    Metric(icon: "bolt", label: "Auto-replies", value: "\(state.autoRepliesSent)", tint: Theme.fbMid)
                    Metric(icon: "calendar", label: "Agenda items", value: "\(tour.agenda.count)", tint: Theme.fbMid) { state.selection = .agenda }
                }

                if !officials.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Officials & assistants (\(officials.count)) — answer in Gmail", systemImage: "building.columns")
                            .font(.caption.bold())
                        ForEach(officials.prefix(6)) { o in
                            Link(destination: URL(string: "https://mail.google.com/mail/u/0/#all/\(o.message.threadId)")!) {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        if o.identity.record?.vip == true { VIPBadge() }
                                        Text(o.message.subject).font(.callout).lineLimit(1)
                                    }
                                    Text("\(o.message.fromName) · \(o.message.date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2).opacity(0.75)
                                }
                            }
                            .foregroundStyle(.white)
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .insetPanel(cornerRadius: 14, tint: Theme.usRed.opacity(0.4))
                }

                if let next {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Next on the agenda", systemImage: "clock").font(.caption).opacity(0.75)
                        Text(next.title).font(.callout.bold()).lineLimit(2)
                        Text(next.start.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute())).font(.caption).opacity(0.8)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .insetPanel(cornerRadius: 14)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Connections").font(.caption).opacity(0.75)
                    ConnectionDot(name: "Salesforce", on: state.salesforceConnected)
                    ConnectionDot(name: "Google", on: state.googleConnected)
                    ConnectionDot(name: "Gemini", on: state.gemini.isConfigured)
                    if let s = state.lastScan { Text("Inbox scanned \(s.formatted(date: .omitted, time: .shortened))").font(.caption2).opacity(0.6) }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .insetPanel(cornerRadius: 14)
            }
            .padding(14)
        }
        .foregroundStyle(.white)
        .glassPanel(cornerRadius: 22)
    }
}

struct Metric: View {
    let icon: String
    let label: String
    let value: String
    var tint: Color = Theme.fbMid
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) { tile }.buttonStyle(.plain)
        } else {
            tile   // informational only — not a disabled (greyed-out) button
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).font(.caption).opacity(0.85)
            Text(value).font(Theme.font(24, .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).opacity(0.85).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetPanel(cornerRadius: 14, tint: tint.opacity(0.4))
    }
}

struct ConnectionDot: View {
    let name: String
    let on: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(on ? Color.green : Color.gray).frame(width: 7, height: 7)
            Text(name).font(.caption)
            Spacer()
            Text(on ? "connected" : "not set up").font(.caption2).opacity(0.6)
        }
    }
}

// MARK: - Footer: partner logos

struct PartnerFooter: View {
    @Environment(AppState.self) private var state
    var body: some View {
        HStack(spacing: 14) {
            Text("A cooperation of").font(.caption).foregroundStyle(.white.opacity(0.8))
            ForEach(Partner.allCases) { p in
                PartnerLogo(partner: p, height: 30)
                    .foregroundStyle(Theme.fbBlue)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white))
                    .help(p.name)
            }
            Spacer()
            // App and Salesforce backend are built and maintained by Scalefree
            let sponsored = state.geminiSponsored
            if !sponsored && state.geminiConfigured {
                // someone else's key: say so, separate from the Scalefree credit
                Text("Custom Gemini AI key applied").font(.caption).foregroundStyle(.white.opacity(0.7))
                    .padding(.trailing, 10)
            }
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Created and maintained by")
                    if sponsored { Text("Gemini AI is sponsored by") }
                }
                .font(.caption).foregroundStyle(.white.opacity(0.8))
                if let sf = BrandImage.load("scalefree-white", trimWhitespace: false) {
                    Image(nsImage: sf).resizable().scaledToFit().frame(height: 34)
                        .accessibilityLabel("Scalefree")
                } else {
                    Text("Scalefree").font(.caption.bold()).foregroundStyle(.white)
                }
            }
            .help("Fulbright Study Tours app and Salesforce backend by Scalefree")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassPanel(cornerRadius: 18)
    }
}

/// Debug helper: `StudyTours --snapshot <dir>` renders each main screen to PNG and quits.
enum Snapshot {
    static let active = CommandLine.arguments.contains("--snapshot")
    @MainActor static func runIfRequested(_ state: AppState) {
        let args = CommandLine.arguments
        // `--capture <dir>`: like --snapshot, but photographs the real window with screencapture,
        // so Liquid Glass is rendered (used for the README screenshots).
        if let i = args.firstIndex(of: "--capture"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            let screens: [(String, SidebarItem)] = [("overview", .overview), ("host-lists", .phase(.submissions)),
                                                    ("registration", .phase(.registration)), ("agenda", .agenda)]
            Task { @MainActor in
                for (name, item) in screens {
                    state.selection = item
                    try? await Task.sleep(for: .seconds(2))
                    guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.height > 300 }) else { continue }
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", dir.appendingPathComponent("\(name).png").path]
                    try? p.run(); p.waitUntilExit()
                }
                NSApp.terminate(nil)
            }
            return
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let screens: [(String, SidebarItem)] = [("overview", .overview), ("registration", .phase(.registration)),
                                                ("submissions", .phase(.submissions)), ("agenda", .agenda), ("inbox", .inbox)]
        Task { @MainActor in
            for (name, item) in screens {
                state.selection = item
                try? await Task.sleep(for: .seconds(1.5))
                guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let v = w.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            }
            NSApp.terminate(nil)
        }
    }
}

struct NewProgramSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var nameEdited = false
    @State private var city = ""
    @State private var start = Calendar.current.date(byAdding: .day, value: 120, to: Date())!
    @State private var end = Calendar.current.date(byAdding: .day, value: 123, to: Date())!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New study tour").font(.title2.bold())
            Text("Creates a program (Campaign) in Salesforce. The whole team sees it in the program list.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("City / region", text: $city)
                DatePicker("Start", selection: $start, displayedComponents: .date)
                DatePicker("End", selection: $end, in: start..., displayedComponents: .date)
                TextField("Program name", text: Binding(get: { nameEdited ? name : suggested }, set: { name = $0; nameEdited = true }))
                Text("The program name is the tour's title in the app and in Salesforce.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create in Salesforce") { state.createProgramTour(name: finalName, start: start, end: end, city: city); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(finalName.trimmingCharacters(in: .whitespaces).isEmpty || city.isEmpty)
            }
        }
        .padding(20).frame(width: 460)
    }

    /// "Study Tour <City> <Year>" — follows city and start date until edited by hand.
    private var suggested: String {
        let year = Calendar.current.component(.year, from: start)
        let c = city.trimmingCharacters(in: .whitespaces)
        return c.isEmpty ? "Study Tour \(year)" : "Study Tour \(c) \(year)"
    }
    private var finalName: String { nameEdited ? name : suggested }
}
