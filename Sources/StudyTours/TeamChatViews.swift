import SwiftUI
import StudyToursCore

/// Right column, below "At a Glance": the team's Google Chat space. Reads and posts as the signed-in Google user.
struct TeamChatPanel: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                Text("Team Chat").font(Theme.font(17, .semibold))
                Spacer()
                if state.chatReady {
                    Button { state.shareToTeam(Assistant.teamDigest(state.tour)) } label: { Image(systemName: "list.bullet.clipboard") }
                        .buttonStyle(.plain).help("Insert the team status (overdue and upcoming tasks) — review, then send")
                    Button { Task { await state.refreshChat() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Refresh")
                    if let u = TeamChat.webURL(space: state.chatSpace) {
                        Link(destination: u) { Image(systemName: "arrow.up.right.square") }.help("Open in Google Chat")
                    }
                }
            }
            if !state.settings.google.chatSpaceTitle.isEmpty && state.chatReady {
                Text(state.settings.google.chatSpaceTitle).font(.caption2).opacity(0.7).lineLimit(1)
            }

            if !state.googleConnected {
                placeholder("Connect Google in Settings to see the team chat.")
            } else if state.chatSpace.isEmpty {
                placeholder("Choose the team's Google Chat space in Settings → Connections.")
            } else {
                messages
                if let e = state.chatError {
                    Text(e).font(.caption2).foregroundStyle(Theme.alertOnDark).lineLimit(2).textSelection(.enabled)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    TextField("Message the team…", text: $state.chatDraft, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.12)))
                        .onSubmit { state.sendChat() }
                    Button { state.sendChat() } label: {
                        if state.chatSending { ProgressView().controlSize(.small) }
                        else { Image(systemName: "paperplane.fill") }
                    }
                    .buttonStyle(.plain).padding(6)
                    .disabled(state.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.chatSending)
                    .help("Send to the team space (Return)")
                }
            }
        }
        .padding(14)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassPanel(cornerRadius: 22)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if state.chatMessages.isEmpty {
                        Text("No messages yet.").font(.caption).opacity(0.6)
                    }
                    ForEach(state.chatMessages) { m in
                        ChatBubble(message: m, mine: !state.myChatUserId.isEmpty && m.senderId == state.myChatUserId).id(m.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: state.chatMessages.last?.id) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .onAppear { if let id = state.chatMessages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
        }
        .frame(maxHeight: .infinity)
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text(text).font(.caption).opacity(0.75).multilineTextAlignment(.center)
            Button("Open Settings") { state.selection = .settings }.glassButton()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    let mine: Bool

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(mine ? "You" : message.senderName).font(.caption2.bold())
                Text(message.created.formatted(Calendar.current.isDateInToday(message.created)
                                               ? .dateTime.hour().minute() : .dateTime.day().month().hour().minute()))
                    .font(.caption2).opacity(0.6)
            }
            Text(message.text).font(.callout).textSelection(.enabled)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(mine ? Theme.fbMid.opacity(0.75) : .white.opacity(0.14)))
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}

/// Settings → Connections: pick the team's Google Chat space.
struct ChatSpaceSettings: View {
    @Environment(AppState.self) private var state
    @State private var spaces: [ChatSpace] = []
    @State private var pasted = ""

    var body: some View {
        @Bindable var state = state
        if !spaces.isEmpty {
            Picker("Team chat space", selection: Binding(
                get: { state.settings.google.chatSpace },
                set: { id in
                    state.settings.google.chatSpace = id
                    state.settings.google.chatSpaceTitle = spaces.first { $0.id == id }?.name ?? ""
                    Task { await state.refreshChat() }
                })) {
                Text("Default from config").tag("")
                ForEach(spaces) { Text($0.name).tag($0.id) }
            }
        } else {
            LabeledContent("Team chat space", value: state.chatSpace.isEmpty ? "Not chosen"
                           : (state.settings.google.chatSpaceTitle.isEmpty ? state.chatSpace : state.settings.google.chatSpaceTitle))
        }
        HStack {
            TextField("…or paste the space link from Google Chat", text: $pasted)
            Button("Use") {
                state.settings.google.chatSpace = TeamChat.spaceName(from: pasted)
                state.settings.google.chatSpaceTitle = ""
                pasted = ""
                Task { await state.refreshChat() }
            }
            .disabled(TeamChat.spaceName(from: pasted).isEmpty)
            Button("Load my spaces") { state.run("Loading Google Chat spaces…") { spaces = try await state.google.chatSpaces() } }
                .disabled(!state.googleConnected)
        }
        Text("Messages are read and sent as your own Google account. An admin adds you to the team's Chat space; then pick it here.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
