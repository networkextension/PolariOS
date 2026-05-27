import SwiftUI

/// What the chat panel is showing. Distinct from the sidebar's `ChatTarget`
/// so the panel can hold a full `ChatRoom`/`ChatThread` value rather than
/// just an id.
enum ChatPanelTarget: Hashable {
    case room(ChatRoom)
    case thread(ChatThread)

    static func roomTarget(_ r: ChatRoom) -> ChatPanelTarget { .room(r) }
    static func threadTarget(_ t: ChatThread) -> ChatPanelTarget { .thread(t) }

    var title: String {
        switch self {
        case .room(let r): return r.name.isEmpty ? "(未命名)" : r.name
        case .thread(let t): return t.otherUsername
        }
    }

    var subtitle: String {
        switch self {
        case .room(let r): return r.topic
        case .thread: return ""
        }
    }
}

struct ChatPanelView: View {
    let target: ChatPanelTarget
    @EnvironmentObject var session: SessionStore
    @StateObject private var store = ChatPanelStore()
    @State private var draft = ""
    @State private var expandedThinking: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.messages) { msg in
                            MessageRow(
                                message: msg,
                                isOutbound: msg.senderID == session.currentUser?.userID,
                                isThinkingExpanded: expandedThinking.contains(msg.id),
                                toggleThinking: { toggle(msg.id) }
                            )
                            .id(msg.id)
                        }
                        if let err = store.error {
                            Text(err).foregroundStyle(.red).font(.caption).padding(.horizontal)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .onChange(of: store.lastReceivedID) { _ in
                    if let last = store.messages.last {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            Divider()
            composer
        }
        .onAppear {
            store.attach(target: target, currentUserID: session.currentUser?.userID)
        }
        .onDisappear { store.detach() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            switch target {
            case .room(let r):
                Image(systemName: "person.3")
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.name.isEmpty ? "(未命名)" : r.name).font(.headline)
                    if !r.topic.isEmpty {
                        Text(r.topic).font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .thread(let t):
                Circle().fill(.secondary.opacity(0.3)).frame(width: 28, height: 28)
                    .overlay(Text(String(t.otherUsername.prefix(1)).uppercased()).font(.callout))
                Text(t.otherUsername).font(.headline)
            }
            Spacer()
            connectionBadge
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var connectionBadge: some View {
        switch store.wsState {
        case .connected:
            return AnyView(Label("已连接", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.green).font(.caption))
        case .connecting, .reconnecting:
            return AnyView(Label("连接中", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange).font(.caption))
        case .disconnected:
            return AnyView(Label("未连接", systemImage: "wifi.slash")
                .foregroundStyle(.secondary).font(.caption))
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $draft)
                .frame(minHeight: 38, maxHeight: 120)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
                .font(.body)

            Button {
                send()
            } label: {
                Image(systemName: "paperplane.fill")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSending)
        }
        .padding(12)
    }

    private func toggle(_ id: Int) {
        if expandedThinking.contains(id) {
            expandedThinking.remove(id)
        } else {
            expandedThinking.insert(id)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.send(text)
        draft = ""
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let isOutbound: Bool
    let isThinkingExpanded: Bool
    let toggleThinking: () -> Void

    var body: some View {
        let (thinking, body) = splitThinking(message.content)
        HStack(alignment: .top) {
            if isOutbound { Spacer(minLength: 60) }
            VStack(alignment: isOutbound ? .trailing : .leading, spacing: 4) {
                if !isOutbound {
                    Text(message.senderUsername)
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if !thinking.isEmpty {
                        ThinkingPanel(
                            text: thinking,
                            isActive: message.streaming,
                            isExpanded: isThinkingExpanded,
                            toggle: toggleThinking
                        )
                    }
                    if body.isEmpty && message.streaming {
                        Text("正在生成…").italic().foregroundStyle(.secondary)
                    } else {
                        MarkdownView(text: body)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isOutbound ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                )
            }
            if !isOutbound { Spacer(minLength: 60) }
        }
    }
}

private struct ThinkingPanel: View {
    let text: String
    let isActive: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(isActive ? "正在思考…" : "思考过程")
                        .font(.caption).fontWeight(.medium)
                }.foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(text)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.08)))
            }
        }
    }
}

private func splitThinking(_ content: String) -> (thinking: String, body: String) {
    var thinking: [String] = []
    var body = content
    while let openRange = body.range(of: "<think>") {
        let afterOpen = openRange.upperBound
        if let closeRange = body.range(of: "</think>", range: afterOpen..<body.endIndex) {
            thinking.append(String(body[afterOpen..<closeRange.lowerBound]))
            body.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        } else {
            thinking.append(String(body[afterOpen..<body.endIndex]))
            body.removeSubrange(openRange.lowerBound..<body.endIndex)
            break
        }
    }
    return (
        thinking.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines),
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    )
}

@MainActor
final class ChatPanelStore: ObservableObject, ChatWebSocketClientDelegate {
    @Published var messages: [ChatMessage] = []
    @Published var error: String?
    @Published var isSending = false
    @Published var wsState: ChatWebSocketConnectionState = .disconnected
    @Published var lastReceivedID: Int = 0

    private let chatService = ChatService()
    private let roomService = RoomService()
    private let ws = ChatWebSocketClient()
    private var target: ChatPanelTarget?
    private var llmThreadID: Int?
    private var currentUserID: String?

    func attach(target: ChatPanelTarget, currentUserID: String?) {
        self.target = target
        self.currentUserID = currentUserID
        // Cached snapshot for instant render.
        switch target {
        case .thread(let t):
            if let cached = ChatLocalStore.shared.load(chatID: t.id) {
                self.messages = cached
            }
        case .room(let r):
            // Rooms reuse the same cache keyed by id (high ids unlikely to
            // collide with thread ids in practice; cheap and good enough).
            if let cached = ChatLocalStore.shared.load(chatID: Int(r.id)) {
                self.messages = cached
            }
        }
        ws.delegate = self
        ws.connect()
        if case .thread(let t) = target {
            chatService.fetchBotLLMThreads(chatID: t.id) { [weak self] result in
                DispatchQueue.main.async {
                    if case .success((_, let active)) = result {
                        self?.llmThreadID = active?.id
                    }
                    self?.refresh()
                }
            }
        } else {
            refresh()
        }
    }

    func detach() {
        ws.disconnect()
        switch target {
        case .thread(let t): ChatLocalStore.shared.flush(chatID: t.id)
        case .room(let r): ChatLocalStore.shared.flush(chatID: Int(r.id))
        case .none: break
        }
    }

    func refresh() {
        guard let target else { return }
        switch target {
        case .thread(let t):
            chatService.fetchMessages(chatID: t.id, llmThreadID: llmThreadID) { [weak self] result in
                self?.handleFetched(result, cacheKey: t.id)
            }
        case .room(let r):
            roomService.fetchMessages(roomID: r.id) { [weak self] result in
                self?.handleFetched(result, cacheKey: Int(r.id))
            }
        }
    }

    private func handleFetched(_ result: Result<[ChatMessage], Error>, cacheKey: Int) {
        DispatchQueue.main.async {
            switch result {
            case .success(let list):
                self.messages = list.sorted { $0.id < $1.id }
                self.lastReceivedID = self.messages.last?.id ?? 0
                ChatLocalStore.shared.save(chatID: cacheKey, messages: self.messages)
            case .failure(let err):
                self.error = err.localizedDescription
            }
        }
    }

    func send(_ text: String) {
        guard let target else { return }
        isSending = true
        switch target {
        case .thread(let t):
            chatService.sendMessage(chatID: t.id, content: text, llmThreadID: llmThreadID) { [weak self] result in
                DispatchQueue.main.async {
                    self?.isSending = false
                    if case .failure(let err) = result { self?.error = err.localizedDescription }
                    self?.refresh()
                }
            }
        case .room(let r):
            roomService.sendMessage(roomID: r.id, content: text) { [weak self] result in
                DispatchQueue.main.async {
                    self?.isSending = false
                    switch result {
                    case .success(let msg):
                        // Echo locally — WS may also deliver it via room_message,
                        // and the id-based dedupe in handle(_:) covers that.
                        if !(self?.messages.contains(where: { $0.id == msg.id }) ?? false) {
                            self?.messages.append(msg)
                            self?.lastReceivedID = msg.id
                        }
                    case .failure(let err):
                        self?.error = err.localizedDescription
                    }
                }
            }
        }
    }

    // MARK: ChatWebSocketClientDelegate
    nonisolated func chatWebSocketClient(_ client: ChatWebSocketClient, didReceive event: ChatWebSocketEvent) {
        Task { @MainActor in self.handle(event) }
    }
    nonisolated func chatWebSocketClient(_ client: ChatWebSocketClient, didChangeState state: ChatWebSocketConnectionState) {
        Task { @MainActor in self.wsState = state }
    }

    private func handle(_ event: ChatWebSocketEvent) {
        guard let target else { return }
        switch (event.type, target) {
        case ("message", .thread(let t)) where event.chatID == t.id:
            applyIncoming(event.message)
        case ("room_message", .room(let r)) where event.roomID == r.id:
            applyIncoming(event.message)
        case ("revoke", .thread(let t)) where event.chatID == t.id:
            markDeleted(event.messageID)
        case ("revoke", .room(let r)) where event.roomID == r.id:
            markDeleted(event.messageID)
        case ("read", _), ("presence", _):
            // Read receipts + online indicators — receive but no UI yet.
            break
        default:
            break
        }
    }

    private func applyIncoming(_ incoming: ChatMessage?) {
        guard let incoming else { return }
        if let idx = messages.firstIndex(where: { $0.id == incoming.id }) {
            let existing = messages[idx]
            if incoming.seq >= existing.seq {
                messages[idx] = incoming
            }
        } else {
            messages.append(incoming)
            messages.sort { $0.id < $1.id }
        }
        lastReceivedID = incoming.id
        persistCache()
    }

    private func markDeleted(_ id: Int?) {
        guard let id, let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].deleted = true
        persistCache()
    }

    private func persistCache() {
        switch target {
        case .thread(let t): ChatLocalStore.shared.save(chatID: t.id, messages: messages)
        case .room(let r): ChatLocalStore.shared.save(chatID: Int(r.id), messages: messages)
        case .none: break
        }
    }
}
