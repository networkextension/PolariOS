import Foundation

/// Qunliao P3 — per-(room, bot) "speak up on your own" config. Backend
/// surface in gin-auth-app/internal/app/dock/chat_rooms_handlers.go,
/// shipped via PR #273. All three routes are owner-only on the server
/// (non-owners get 403; `listLoops` returns notSupported semantics that
/// surface as RoomServiceError.notSupported so non-owner UI can stay
/// quiet).

struct AgentLoop: Codable, Hashable, Identifiable {
    let roomID: Int64
    let botUserID: String
    var enabled: Bool
    var intervalSecs: Int          // server gate: 60-3600
    var maxPerHour: Int            // server gate: 1-30
    let lastDecidedAt: String?
    let lastPostedAt: String?
    let decisionsThisHour: Int
    let hourWindowStart: String?

    var id: String { "\(roomID)_\(botUserID)" }

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case botUserID = "bot_user_id"
        case enabled
        case intervalSecs = "interval_secs"
        case maxPerHour = "max_per_hour"
        case lastDecidedAt = "last_decided_at"
        case lastPostedAt = "last_posted_at"
        case decisionsThisHour = "decisions_this_hour"
        case hourWindowStart = "hour_window_start"
    }
}

private struct AgentLoopListResponse: Decodable { let loops: [AgentLoop] }
private struct AgentLoopOKResponse: Decodable { let ok: Bool? }

final class AgentLoopService {
    private let apiClient = APIClient.shared

    /// Owner-only on the server. Non-owners get 403, which surfaces as
    /// an NSError — callers should map 403 to "feature unavailable".
    func listLoops(roomID: Int64, completion: @escaping (Result<[AgentLoop], Error>) -> Void) {
        apiClient.requestDecodable(
            path: "/api/rooms/\(roomID)/agent-loops",
            errorDomain: "AgentLoopService"
        ) { (result: Result<AgentLoopListResponse, Error>) in
            completion(result.map { $0.loops })
        }
    }

    /// Upsert a loop for a bot member. Server requires the bot to already
    /// be a chat_room_members row in this room (400 "先加成员…" otherwise).
    /// `intervalSecs` is clamped server-side to [60, 3600]; `maxPerHour` to
    /// [1, 30]. Passing 0 lets the server fill the defaults (300s, 4/h).
    func upsertLoop(roomID: Int64, botUserID: String, enabled: Bool, intervalSecs: Int = 0, maxPerHour: Int = 0, completion: @escaping (Result<Void, Error>) -> Void) {
        var body: [String: Any] = ["enabled": enabled]
        if intervalSecs > 0 { body["interval_secs"] = intervalSecs }
        if maxPerHour > 0 { body["max_per_hour"] = maxPerHour }
        apiClient.requestDecodable(
            path: "/api/rooms/\(roomID)/agent-loops/\(botUserID)",
            method: "PUT",
            jsonBody: body,
            errorDomain: "AgentLoopService"
        ) { (result: Result<AgentLoopOKResponse, Error>) in
            completion(result.map { _ in () })
        }
    }

    /// Disable + clear the row. Equivalent to upsert(enabled: false) plus a
    /// forget of the per-hour counter.
    func deleteLoop(roomID: Int64, botUserID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        apiClient.requestDecodable(
            path: "/api/rooms/\(roomID)/agent-loops/\(botUserID)",
            method: "DELETE",
            errorDomain: "AgentLoopService"
        ) { (result: Result<AgentLoopOKResponse, Error>) in
            completion(result.map { _ in () })
        }
    }
}
