import SwiftUI

enum ChatTarget: Hashable, Identifiable {
    case room(Int64)
    case thread(Int)

    var id: String {
        switch self {
        case .room(let id): return "r-\(id)"
        case .thread(let id): return "t-\(id)"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var rooms = RoomListStore()
    @StateObject private var threads = ChatListStore()
    @StateObject private var teams = TeamPickerStore()
    @State private var selected: ChatTarget?
    @State private var showCreateRoom = false

    var body: some View {
        NavigationSplitView {
            ChatSidebar(
                rooms: rooms.rooms,
                roomsState: rooms.state,
                threads: threads.threads,
                threadsLoading: threads.isLoading,
                threadsError: threads.error,
                selected: $selected,
                onRefresh: refreshAll,
                onCreateRoom: { showCreateRoom = true }
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            switch selected {
            case .room(let id):
                if let room = rooms.rooms.first(where: { $0.id == id }) {
                    ChatPanelView(target: .roomTarget(room)).id(room.id)
                } else { unavailable }
            case .thread(let id):
                if let thread = threads.threads.first(where: { $0.id == id }) {
                    ChatPanelView(target: .threadTarget(thread)).id(thread.id)
                } else { unavailable }
            case .none:
                unavailable
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(session.currentUser?.username ?? "").font(.headline)
            }
            ToolbarItem(placement: .primaryAction) {
                workspaceMenu
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: refreshAll) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("退出登录", role: .destructive, action: session.logout)
                } label: {
                    Image(systemName: "person.circle")
                }
            }
        }
        .onAppear {
            teams.refresh()
            refreshAll()
        }
        .onChange(of: session.currentWorkspaceID) { _ in
            selected = nil
            refreshAll()
        }
        .sheet(isPresented: $showCreateRoom) {
            CreateRoomSheet(store: rooms, onCreated: { newRoom in
                selected = .room(newRoom.id)
            })
        }
    }

    private var unavailable: some View {
        ContentUnavailableViewCompat(
            title: "选择左侧会话开始",
            subtitle: rooms.state.isUnsupported
                ? "当前后端没有 /api/rooms 接口，先用私聊。"
                : "群聊在左上，私聊在左下。\n看不到预期的群聊？右上角切换工作区。"
        )
    }

    private var workspaceMenu: some View {
        Menu {
            Button {
                session.currentWorkspaceID = nil
            } label: {
                HStack {
                    if session.currentWorkspaceID == nil {
                        Image(systemName: "checkmark")
                    }
                    Text("个人（默认）")
                }
            }
            if !teams.teams.isEmpty {
                Divider()
                ForEach(teams.teams) { team in
                    Button {
                        session.currentWorkspaceID = team.id
                    } label: {
                        HStack {
                            if session.currentWorkspaceID == team.id {
                                Image(systemName: "checkmark")
                            }
                            Text("\(team.name) · \(team.myRole)")
                        }
                    }
                }
            }
            Divider()
            Button {
                teams.refresh()
            } label: {
                Label("刷新团队列表", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "building.2")
                Text(currentWorkspaceName).lineLimit(1)
            }
        }
        .help("切换 X-Workspace-Id；rooms 是按工作区隔离的")
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var currentWorkspaceName: String {
        if let id = session.currentWorkspaceID,
           let team = teams.teams.first(where: { $0.id == id }) {
            return team.name
        }
        return "个人"
    }

    private func refreshAll() {
        rooms.refresh()
        threads.refresh()
    }
}

struct ContentUnavailableViewCompat: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .resizable().scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundStyle(.secondary.opacity(0.5))
            Text(title).font(.title2)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class ChatListStore: ObservableObject {
    @Published var threads: [ChatThread] = []
    @Published var isLoading = false
    @Published var error: String?

    private let chatService = ChatService()

    func refresh() {
        isLoading = true
        chatService.fetchChats { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let list):
                    self.threads = list
                    self.error = nil
                case .failure(let err):
                    self.error = err.localizedDescription
                }
            }
        }
    }
}

@MainActor
final class RoomListStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case unsupported          // backend doesn't have rooms yet (404)
        case error(String)

        var isUnsupported: Bool {
            if case .unsupported = self { return true } else { return false }
        }
    }

    @Published var rooms: [ChatRoom] = []
    @Published var state: LoadState = .idle

    private let roomService = RoomService()

    func refresh() {
        state = .loading
        roomService.listRooms { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let list):
                    self.rooms = list
                    self.state = .loaded
                case .failure(RoomServiceError.notSupported):
                    self.rooms = []
                    self.state = .unsupported
                case .failure(let err):
                    self.state = .error(err.localizedDescription)
                }
            }
        }
    }

    func create(name: String, topic: String, completion: @escaping (Result<ChatRoom, Error>) -> Void) {
        roomService.createRoom(name: name, topic: topic) { [weak self] result in
            DispatchQueue.main.async {
                if case .success(let room) = result {
                    self?.rooms.insert(room, at: 0)
                }
                completion(result)
            }
        }
    }
}

struct CreateRoomSheet: View {
    @ObservedObject var store: RoomListStore
    var onCreated: (ChatRoom) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var topic = ""
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建群聊").font(.title3).bold()
            Form {
                TextField("名称", text: $name).textFieldStyle(.roundedBorder)
                TextField("主题（可选）", text: $topic).textFieldStyle(.roundedBorder)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(submitting ? "创建中…" : "创建") {
                    submitting = true
                    store.create(name: name.trimmingCharacters(in: .whitespacesAndNewlines), topic: topic) { result in
                        submitting = false
                        switch result {
                        case .success(let room):
                            onCreated(room); dismiss()
                        case .failure(let err):
                            error = err.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitting)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
