import SwiftUI

struct ChatSidebar: View {
    let rooms: [ChatRoom]
    let roomsState: RoomListStore.LoadState
    let threads: [ChatThread]
    let threadsLoading: Bool
    let threadsError: String?
    @Binding var selected: ChatTarget?
    let onRefresh: () -> Void
    let onCreateRoom: () -> Void

    var body: some View {
        List(selection: $selected) {
            Section {
                if case .unsupported = roomsState {
                    Text("后端无 /api/rooms 接口")
                        .font(.caption).foregroundStyle(.secondary)
                } else if case .loading = roomsState, rooms.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("加载中…").font(.caption) }
                } else if case .error(let msg) = roomsState, rooms.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("加载失败").font(.caption).foregroundStyle(.red)
                        Text(msg).font(.caption2).foregroundStyle(.secondary)
                    }
                } else if rooms.isEmpty {
                    Text("还没有群聊。点右上 + 创建。").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(rooms) { room in
                        RoomRow(room: room).tag(ChatTarget.room(room.id))
                    }
                }
            } header: {
                HStack {
                    Label("群聊", systemImage: "person.3").font(.subheadline.bold())
                    Spacer()
                    Button(action: onCreateRoom) {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(roomsState.isUnsupported)
                    .help("新建群聊")
                }
            }

            Section {
                if threads.isEmpty && threadsLoading {
                    HStack { ProgressView().controlSize(.small); Text("加载中…").font(.caption) }
                } else if let err = threadsError, threads.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("加载失败").font(.caption).foregroundStyle(.red)
                        Text(err).font(.caption2).foregroundStyle(.secondary)
                    }
                } else if threads.isEmpty {
                    Text("还没有私聊").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(threads) { thread in
                        ThreadRow(thread: thread).tag(ChatTarget.thread(thread.id))
                    }
                }
            } header: {
                Label("私聊", systemImage: "bubble.left").font(.subheadline.bold())
            }
        }
        .listStyle(.sidebar)
    }
}

private struct RoomRow: View {
    let room: ChatRoom

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconFor(kind: room.kind))
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name.isEmpty ? "(未命名)" : room.name)
                    .font(.body).lineLimit(1)
                if !room.topic.isEmpty {
                    Text(room.topic).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private func iconFor(kind: String) -> String {
        switch kind {
        case "convene": return "rectangle.3.group"
        case "whisper": return "ear"
        case "dm": return "person"
        default: return "person.3"
        }
    }
}

private struct ThreadRow: View {
    let thread: ChatThread

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.secondary.opacity(0.3))
                .frame(width: 28, height: 28)
                .overlay(Text(String(thread.otherUsername.prefix(1)).uppercased()).font(.callout))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.otherUsername).font(.body).lineLimit(1)
                    Spacer()
                    if thread.unreadCount > 0 {
                        Text("\(thread.unreadCount)")
                            .font(.caption2).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
                Text(thread.lastMessage.isEmpty ? "无消息" : thread.lastMessage)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
