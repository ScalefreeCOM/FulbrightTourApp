import SwiftUI
import AppKit
import UniformTypeIdentifiers
import StudyToursCore

struct SettingsView: View {
    var body: some View {
        TabView {
            ConnectionsSettings().tabItem { Label("Connections", systemImage: "link") }
            AssistantSettingsView().tabItem { Label("Email assistant", systemImage: "envelope.badge") }
            BrandingSettings().tabItem { Label("Branding", systemImage: "photo") }
        }
        .padding(20)
    }
}

struct SecretField: View {
    let title: String
    let key: String
    @State private var value = ""
    @State private var stored = false

    var body: some View {
        HStack {
            SecureField(title, text: $value, prompt: Text(stored ? "•••••••• (saved in Keychain)" : title))
            Button("Save") { Keychain.set(value, for: key); value = ""; stored = Keychain.get(key) != nil }.disabled(value.isEmpty)
            if stored { Button("Remove") { Keychain.set(nil, for: key); stored = false } }
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
                Text("Sign in with the Fulbright mailbox account. Scopes: Gmail modify, Drive, Docs, Calendar events, Chat messages and spaces (read), directory (sender names in the chat).").font(.caption).foregroundStyle(.secondary)
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
                Stepper("Passport must be valid \(state.settings.cleansing.passportMinValidityMonths) months after the tour",
                        value: $state.settings.cleansing.passportMinValidityMonths, in: 0...24)
            }
            Section("Automatic replies to attendees") {
                Toggle("Send replies automatically", isOn: $state.settings.assistant.autoSend)
                Text("Only when: sender is a member (Lead) in Salesforce · mail is about the tour · not high importance · the assistant is confident and needed no missing facts. Officials (Contacts) are never answered automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Max \(state.settings.assistant.autoSendMaxPerRun) automatic replies per scan", value: $state.settings.assistant.autoSendMaxPerRun, in: 1...50)
                TextField("Tone", text: $state.settings.assistant.tone)
                TextField("Signature", text: $state.settings.assistant.signature, axis: .vertical).lineLimit(2...5)
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
