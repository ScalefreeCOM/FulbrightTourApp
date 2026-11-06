import SwiftUI
import AppKit
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
        .sheet(item: Binding(get: { state.signIn }, set: { if $0 == nil { state.cancelSignIn() } })) { SignInSheet(prompt: $0) }
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
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt.url.absoluteString, forType: .string)
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
            Section("Google Gemini") {
                SecretField(title: "Gemini API key", key: Keychain.Key.geminiKey)
                HStack {
                    TextField("Model", text: $state.settings.gemini.model)
                    Button("List models") { state.run("Loading models…") { models = try await state.gemini.listModels() } }
                }
                if !models.isEmpty {
                    Picker("Available", selection: $state.settings.gemini.model) { ForEach(models, id: \.self) { Text($0).tag($0) } }
                }
                Toggle("Redact ID/passport/phone-like numbers before sending mail text to Gemini", isOn: $state.settings.gemini.redactNumbers)
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
                    Button("Choose…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg]
                        if panel.runModal() == .OK, let u = panel.url { install(u, for: p) }
                    }
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
