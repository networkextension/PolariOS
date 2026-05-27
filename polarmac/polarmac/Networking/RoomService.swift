import Foundation

/// Multi-participant chat rooms. Backend surface defined in
/// gin-auth-app/internal/app/dock/chat_rooms_handlers.go (merged via
/// PR #264/#265/#268 — qunliao P0a/P0b/P0c-1). Workspace-scoped —
/// caller's personal workspace is used by default (server falls back
/// when X-Workspace-Id is unset).

struct ChatRoom: Decodable, Identifiable, Hashable {
    let id: Int64
    let workspaceID: String
    let kind: String           // "room" | "dm" | "whisper" | "convene"
    let name: String
    let topic: String
    let createdByUserID: String
    let createdAt: String
    let archivedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspace_id"
        case kind
        case name
        case topic
        case createdByUserID = "created_by_user_id"
        case createdAt = "created_at"
        case archivedAt = "archived_at"
    }
}

struct ChatRoomMember: Decodable, Identifiable, Hashable {
    let roomID: Int64
    let userID: String
    let role: String           // "owner" | "member" | "observer"
    let joinedAt: String
    let lastReadMessageID: Int64?
    // Denormalized display fields populated by listChatRoomMembers
    // (PR #274). `botName` is the @mention token clients should surface;
    // `isBot` is the authoritative flag (don't sniff user_id prefix).
    let username: String?
    let icon: String?
    let isBot: Bool?
    let botName: String?

    var id: String { "\(roomID)_\(userID)" }

    /// Display label — prefer the joined username, fall back to opaque user_id
    /// so older payloads still render.
    var displayName: String {
        username?.isEmpty == false ? username! : userID
    }

    /// @mention token to copy into the composer (P1 fanout looks up by
    /// bot_users.name not user_id). nil for human members.
    var mentionToken: String? {
        guard isBot == true, let name = botName, !name.isEmpty else { return nil }
        return "@\(name)"
    }

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case userID = "user_id"
        case role
        case joinedAt = "joined_at"
        case lastReadMessageID = "last_read_message_id"
        case username
        case icon
        case isBot = "is_bot"
        case botName = "bot_name"
    }
}

private struct RoomListResponse: Decodable { let rooms: [ChatRoom] }
private struct RoomDetailResponse: Decodable { let room: ChatRoom; let member: ChatRoomMember? }
private struct RoomCreateResponse: Decodable { let room: ChatRoom }
private struct RoomMembersResponse: Decodable { let members: [ChatRoomMember] }
private struct RoomMessageListResponse: Decodable { let messages: [ChatMessage] }
private struct RoomMessageCreateResponse: Decodable { let message: ChatMessage }
private struct OKResponse: Decodable { let ok: Bool? }

/// Reasons a room-related call may legitimately fail without being a real bug.
enum RoomServiceError: Error {
    case notSupported  // server returned 404 — likely older backend without qunliao P0
}

final class RoomService {
    private let apiClient = APIClient.shared

    func listRooms(includeArchived: Bool = false, completion: @escaping (Result<[ChatRoom], Error>) -> Void) {
        let suffix = includeArchived ? "?include_archived=1" : ""
        apiClient.requestDecodable(
            path: "/api/rooms\(suffix)",
            errorDomain: "RoomService"
        ) { (result: Result<RoomListResponse, Error>) in
            completion(result.map { $0.rooms }.mapNotSupported())
        }
    }

    func createRoom(kind: String = "room", name: String, topic: String = "", completion: @escaping (Result<ChatRoom, Error>) -> Void) {
        apiClient.requestDecodable(
            path: "/api/rooms",
            method: "POST",
            jsonBody: ["kind": kind, "name": name, "topic": topic],
            errorDomain: "RoomService"
        ) { (result: Result<RoomCreateResponse, Error>) in
            completion(result.map { $0.room })
        }
    }

    func fetchRoom(id: Int64, completion: @escaping (Result<(ChatRoom, ChatRoomMember?), Error>) -> Void) {
        apiClient.requestDecodable(
            path: "/api/rooms/\(id)",
            errorDomain: "RoomService"
        ) { (result: Result<RoomDetailResponse, Error>) in
            completion(result.map { ($0.room, $0.member) })
        }
    }

    func updateRoom(id: Int64, name: String? = nil, topic: String? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let topic { body["topic"] = topic }
        apiClient.requestDecodable(
            path: "/api/rooms/\(id)",
            method: "PUT",
            jsonBody: body,
            errorDomain: "RoomService"
        ) { (result: Result<OKResponse, Error>) in
            completion(result.map { _ in () })
        }
    }

    /// Soft-archive (sets archived_at = now()). Row is preserved and still
    /// visible via listRooms(includeArchived: true). Owner-only on the server.
    func archiveRoom(id: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
        apiClient.requestDecodable(
            path: "/api/rooms/\(id)",
            method: "DELETE",
            errorDomain: "RoomService"
        ) { (result: Result<OKResponse, Error>) in
            completion(result.map { _ in () })
        }
    }

    func listMembers(roomID: Int64, completion: @escaping (Result<[ChatRoomMember], Error>) -> Void) {
        apiClient.requestDecodable(
            path: "/api/rooms/\(roomID)/members",
            errorDomain: "RoomService"
        ) { (result: Result<RoomMembersResponse, Error>) in
            completion(result.map { $0.members })
        }
    }

    func addMember(roomID: Int64, userID: String, role: String = "member", completion: @escaping (Result<Void, Error>) -> Void) {
        apiClient.requestDecodable(
            path: "/api/rooms/\(roomID)/members",
            method: "POST",
            jsonBody: ["user_id": userID, "role": role],
            errorDomain: "RoomService"
        ) { (result: Result<OKResponse, Error>) in
            completion(result.map { _ in () })
        }
    }

    func removeMember(roomID: Int64, userID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        apiClient.requestDecodable(
            path: "/api/rooms/\(roomID)/members/\(userID)",
            method: "DELETE",
            errorDomain: "RoomService"
        ) { (result: Result<OKResponse, Error>) in
            completion(result.map { _ in () })
        }
    }

    func fetchMessages(roomID: Int64, beforeID: Int64? = nil, limit: Int = 50, completion: @escaping (Result<[ChatMessage], Error>) -> Void) {
        var path = "/api/rooms/\(roomID)/messages?limit=\(limit)"
        if let beforeID {
            path += "&before_id=\(beforeID)"
        }
        apiClient.requestDecodable(
            path: path,
            errorDomain: "RoomService"
        ) { (result: Result<RoomMessageListResponse, Error>) in
            completion(result.map { $0.messages })
        }
    }

    func sendMessage(roomID: Int64, content: String, messageType: String? = nil, completion: @escaping (Result<ChatMessage, Error>) -> Void) {
        var body: [String: Any] = ["content": content]
        if let messageType {
            body["message_type"] = messageType
        }
        apiClient.requestDecodable(
            path: "/api/rooms/\(roomID)/messages",
            method: "POST",
            jsonBody: body,
            errorDomain: "RoomService"
        ) { (result: Result<RoomMessageCreateResponse, Error>) in
            completion(result.map { $0.message })
        }
    }
}

private extension Result where Failure == Error {
    /// If the server replied 404, treat it as "feature not deployed yet" so
    /// the UI can degrade gracefully instead of showing a scary red error.
    func mapNotSupported() -> Result<Success, Error> {
        guard case .failure(let err as NSError) = self,
              err.code == 404 else {
            return self
        }
        return .failure(RoomServiceError.notSupported)
    }
}
