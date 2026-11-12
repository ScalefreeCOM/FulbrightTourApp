import SwiftUI
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers
import StudyToursCore

struct SettingsView: View {
    @Environment(AppState.self) private var state
    var body: some View {
        TabView {
            ConnectionsSettings().tabItem { Label("Connections", systemImage: "link") }
            AssistantSettingsView().tabItem { Label("Email assistant", systemImage: "envelope.badge") }
            BrandingSettings().tabItem { Label("Branding", systemImage: "photo") }
        }
        .padding(20)
        #if os(macOS)
        .sheet(item: Binding(get: { state.signIn }, set: { if $0 == nil { state.cancelSignIn() } })) { SignInSheet(prompt: $0) }
        #endif
    }
}

/// Lets the user open the sign-in page in the browser/profile of their choice (e.g. the one signed in to the Fulbright account).
struct SignInSheet: View {
    @Environment(AppState.self) private var state
    let prompt: SignInPrompt
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to \(prompt.service)").font(.title2.bold())
            Text("Open the sign-in page in the browser where you are signed in with the right account. If that is not your default browser, copy the link and paste it into the other browser or profile.")
                .fixedSize(horizontal: false, vertical: true)
            if prompt.service == "Google" {
                Text("Use your own Google account. If Google says the app isn't verified, choose Advanced → Go to … (unsafe).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for the sign-in… Keep this window open until the browser says “Signed in”.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { state.cancelSignIn() }
                Spacer()
                Button(copied ? "Link copied" : "Copy link") {
                    Platform.copy(prompt.url.absoluteString)
                    copied = true
                }
                Button("Open in default browser") { AppState.open(prompt.url) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

struct SecretField: View {
    @Environment(AppState.self) private var appState
    let title: String
    let key: String
    @State private var value = ""
    @State private var stored = false

    var body: some View {
        HStack {
            SecureField(title, text: $value, prompt: Text(stored ? "•••••••• (saved in Keychain)" : title))
            Button("Save") { Keychain.set(value, for: key); value = ""; stored = Keychain.get(key) != nil; appState.refreshConnectionState() }.disabled(value.isEmpty)
            if stored { Button("Remove") { Keychain.set(nil, for: key); stored = false; appState.refreshConnectionState() } }
        }
        .onAppear { stored = Keychain.get(key) != nil }
    }
}

/// Text that is shown as bullets until the eye button is pressed (client IDs / consumer keys).
struct MaskedField: View {
    let title: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        HStack {
            if revealed { TextField(title, text: $text) } else { SecureField(title, text: $text) }
            Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                .buttonStyle(.borderless).help(revealed ? "Hide" : "Show")
        }
    }
}

struct ConnectionsSettings: View {
    @Environment(AppState.self) private var state
    @State private var models: [String] = []
    @State private var refresh = 0

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Salesforce") {
                LabeledContent("Organisation", value: SalesforceSettings.productionURL)
                SchemaStatus()
                MaskedField(title: "Consumer Key (External Client App)", text: $state.settings.salesforce.clientId)
                Text("Callback URL to register: http://localhost:\(state.settings.salesforce.callbackPort)/callback · OAuth scopes: api, refresh_token · PKCE on").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                status(state.salesforceConnected, state.salesforce.instanceURL) {
                    state.connectSalesforce()
                } disconnect: { state.disconnectSalesforce() }
            }
            Section("Google (Gmail · Drive · Docs · Calendar · Chat)") {
                MaskedField(title: "OAuth client ID (Desktop app)", text: $state.settings.google.clientId)
                SecretField(title: "OAuth client secret", key: Keychain.Key.googleSecret)
                Text("Sign in with your own Google account. Scopes: Gmail modify, Drive, Docs, Calendar events, Chat messages and spaces (read), directory (sender names in the chat).").font(.caption).foregroundStyle(.secondary)
                status(state.googleConnected, "") { state.connectGoogle() } disconnect: { state.disconnectGoogle() }
            }
            Section("Team chat (Google Chat)") {
                ChatSpaceSettings()
            }
            Section("Share keys with the team") {
                TeamKeysSettings()
            }
            Section("AI assistant") {
                Picker("Provider", selection: $state.settings.aiProvider) {
                    ForEach(AIProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: state.settings.aiProvider) { models = []; state.refreshConnectionState() }
                if state.settings.aiProvider == .gemini {
                    SecretField(title: "Gemini API key", key: Keychain.Key.geminiKey)
                    HStack {
                        TextField("Model", text: $state.settings.gemini.model)
                        Button("List models") { state.run("Loading models…") { models = try await state.ai.listModels() } }
                    }
                    if !models.isEmpty {
                        Picker("Available", selection: $state.settings.gemini.model) { ForEach(models, id: \.self) { Text($0).tag($0) } }
                    }
                } else {
                    SecretField(title: "Claude API key", key: Keychain.Key.claudeKey)
                    HStack {
                        TextField("Model", text: $state.settings.claude.model)
                        Button("List models") { state.run("Loading models…") { models = try await state.ai.listModels() } }
                    }
                    if !models.isEmpty {
                        Picker("Available", selection: $state.settings.claude.model) { ForEach(models, id: \.self) { Text($0).tag($0) } }
                    }
                    Picker("Thinking effort", selection: $state.settings.claude.effort) {
                        ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0).tag($0) }
                    }
                    Text("Claude keys come from console.anthropic.com. Higher effort gives more careful drafts but is slower and uses more tokens.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Redact ID/passport/phone-like numbers before sending mail text to the AI", isOn: $state.settings.gemini.redactNumbers)
            }
        }
        .formStyle(.grouped)
        .id(refresh)
    }

    private func status(_ connected: Bool, _ detail: String, connect: @escaping () -> Void, disconnect: @escaping () -> Void) -> some View {
        HStack {
            Circle().fill(connected ? .green : .gray).frame(width: 8)
            Text(connected ? "Connected \(detail)" : "Not connected")
            Spacer()
            if connected { Button("Disconnect", action: disconnect) } else { Button("Connect…", action: connect) }
        }
    }
}

struct SchemaStatus: View {
    @Environment(AppState.self) private var state
    var body: some View {
        HStack {
            Text(state.storageMissingFields.isEmpty ? "All study-tour fields are available"
                 : "Not deployed yet: " + state.storageMissingFields.joined(separator: ", "))
                .font(.caption).foregroundStyle(state.storageMissingFields.isEmpty ? .green : Theme.warnOnDark)
            Spacer()
            Button("Check again") { state.run("Checking Salesforce fields…") { try await state.salesforceStartup() } }
                .disabled(!state.salesforceConnected)
        }
    }
}

struct AssistantSettingsView: View {
    @Environment(AppState.self) private var state
    var body: some View {
        @Bindable var state = state
        Form {
            Section("Inbox") {
                TextField("Gmail search", text: $state.settings.google.inboxQuery)
                Stepper("Scan every \(state.settings.assistant.pollMinutes) min (0 = manual)", value: $state.settings.assistant.pollMinutes, in: 0...120, step: 5)
                TextField("Label for important mail", text: $state.settings.google.importantLabel)
                TextField("Label for answered mail", text: $state.settings.google.answeredLabel)
                TextField("Urgent keywords (comma separated)", text: Binding(
                    get: { state.settings.assistant.urgentKeywords.joined(separator: ", ") },
                    set: { state.settings.assistant.urgentKeywords = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
            }
            Section("Data quality") {
                TextField("Default country calling code", text: $state.settings.cleansing.defaultCountryCallingCode)
                Text("Passports/IDs must be valid until at least one week after the last day of the program.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Reply drafts") {
                Text("Gemini drafts a reply for every mail that needs one — from members, officials and new senders. Nothing is ever sent automatically: you review, edit and send each reply yourself.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Tone", text: $state.settings.assistant.tone)
                Text("Drafts are signed with “Best regards,” and the first name of the Salesforce user who is signed in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: state.settings.assistant.pollMinutes) { state.startPolling() }
    }
}

struct BrandingSettings: View {
    @State private var refresh = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Partner logos").font(.headline)
            Text("Drop a PNG/JPG on a slot (or click to choose). Logos are stored in the app's support folder.").font(.caption).foregroundStyle(.secondary)
            ForEach(Partner.allCases) { p in
                HStack {
                    PartnerLogo(partner: p, height: 44).frame(width: 260, height: 60, alignment: .leading)
                        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(.white))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.secondary))
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                                if let url { DispatchQueue.main.async { install(url, for: p) } }
                            }
                            return true
                        }
                    #if os(macOS)
                    Button("Choose…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg]
                        if panel.runModal() == .OK, let u = panel.url { install(u, for: p) }
                    }
                    #endif
                    Text(p.name)
                }
            }
            Spacer()
        }
        .id(refresh)
    }

    private func install(_ url: URL, for p: Partner) {
        let ext = url.pathExtension.lowercased() == "png" ? "png" : "jpg"
        for e in ["png", "jpg", "jpeg"] { try? FileManager.default.removeItem(at: Store.logosDirectory.appendingPathComponent("\(p.rawValue).\(e)")) }
        try? FileManager.default.copyItem(at: url, to: Store.logosDirectory.appendingPathComponent("\(p.rawValue).\(ext)"))
        BrandImage.invalidate()
        refresh += 1
    }
}


// MARK: - Team key file (encrypted export / import of the shared API keys)

struct TeamKeysDocument: FileDocument {
    static var readableContentTypes: [UTType] { [TeamKeysDocument.type, .json, .data] }
    static let type = UTType(filenameExtension: TeamKeys.fileExtension) ?? .data
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct TeamKeysSettings: View {
    @Environment(AppState.self) private var state
    enum Mode: Identifiable { case export, importFile(Data); var id: String { if case .export = self { "e" } else { "i" } } }
    @State private var mode: Mode?
    @State private var exportDoc: TeamKeysDocument?
    @State private var showExporter = false
    @State private var showImporter = false

    var body: some View {
        Text("Hand the shared keys (AI keys, Google client secret) to a team member as an encrypted file. Personal sign-ins are never included — everyone still signs in to Google and Salesforce themselves. Send the file and the passphrase through different channels, e.g. the file by email and the passphrase by phone.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("Export team key file…") { mode = .export }
            Button("Import team key file…") { showImporter = true }
        }
        .sheet(item: $mode) { m in
            PassphraseSheet(exporting: { if case .export = m { true } else { false } }()) { passphrase in
                switch m {
                case .export:
                    exportDoc = TeamKeysDocument(data: try state.exportTeamKeys(passphrase: passphrase))
                    DispatchQueue.main.async { showExporter = true }
                case .importFile(let data):
                    try state.importTeamKeys(data, passphrase: passphrase)
                }
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportDoc, contentType: TeamKeysDocument.type,
                      defaultFilename: "Fulbright team keys.\(TeamKeys.fileExtension)") { result in
            if case .failure(let e) = result { state.lastError = e.localizedDescription }
            else { state.flash("Team key file saved — send the passphrase separately") }
            exportDoc = nil
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: TeamKeysDocument.readableContentTypes) { result in
            switch result {
            case .success(let url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do { mode = .importFile(try Data(contentsOf: url)) } catch { state.lastError = error.localizedDescription }
            case .failure(let e): state.lastError = e.localizedDescription
            }
        }
    }
}

/// Asks for the passphrase (twice when exporting) and runs the action; errors stay in the sheet.
struct PassphraseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let exporting: Bool
    let action: (String) throws -> Void
    @State private var pass = ""
    @State private var repeatPass = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(exporting ? "Encrypt the team key file" : "Import team key file").font(.headline)
            Text(exporting ? "Choose a passphrase of at least \(TeamKeys.minimumPassphraseLength) characters. Your team member needs it to open the file." :
                             "Enter the passphrase you received separately from the file.")
                .font(.callout).foregroundStyle(.secondary)
            SecureField("Passphrase", text: $pass)
            if exporting { SecureField("Repeat passphrase", text: $repeatPass) }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(exporting ? "Encrypt…" : "Import") {
                    if exporting && pass != repeatPass { error = "The passphrases do not match."; return }
                    do { try action(pass); dismiss() } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pass.count < (exporting ? TeamKeys.minimumPassphraseLength : 1))
            }
        }
        .padding(20).frame(width: 420)
    }
}
