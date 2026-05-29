import Foundation

struct ChatThread: Decodable, Identifiable, Hashable {
    let id: Int
    let otherUserID: String
    let otherUsername: String
    let otherUserIcon: String?
    let lastMessage: String
    let lastMessageAt: String?
    let createdAt: String
    let unreadCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case otherUserID = "other_user_id"
        case otherUsername = "other_username"
        case otherUserIcon = "other_user_icon"
        case userIcon = "user_icon"
        case lastMessage = "last_message"
        case lastMessageAt = "last_message_at"
        case createdAt = "created_at"
        case unreadCount = "unread_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        otherUserID = try container.decode(String.self, forKey: .otherUserID)
        otherUsername = try container.decode(String.self, forKey: .otherUsername)
        otherUserIcon = try container.decodeIfPresent(String.self, forKey: .otherUserIcon) ?? container.decodeIfPresent(String.self, forKey: .userIcon)
        lastMessage = try container.decode(String.self, forKey: .lastMessage)
        lastMessageAt = try container.decodeIfPresent(String.self, forKey: .lastMessageAt)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        unreadCount = try container.decode(Int.self, forKey: .unreadCount)
    }
}

struct ChatMessage: Codable, Identifiable, Hashable {
    let id: Int
    let threadID: Int?
    let roomID: Int64?
    let llmThreadID: Int?
    let senderID: String
    let senderUsername: String
    let senderIcon: String?
    let messageType: String
    var content: String
    let createdAt: String
    var updatedAt: String?
    let failed: Bool
    var deleted: Bool
    var streaming: Bool
    var seq: Int64
    let llmConfigID: Int?
    let llmConfigName: String?
    let llmModel: String?
    // Per-message telemetry snapshot (qunliao β PR #276). Populated for
    // bot replies; nil on user posts and on quota/error placeholders.
    let latencyMs: Int?
    let promptTokens: Int?
    let completionTokens: Int?
    let costUSD: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case threadID = "thread_id"
        case roomID = "room_id"
        case llmThreadID = "llm_thread_id"
        case senderID = "sender_id"
        case senderUsername = "sender_username"
        case senderIcon = "sender_icon"
        case messageType = "message_type"
        case content
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case failed
        case deleted
        case streaming
        case seq
        case llmConfigID = "llm_config_id"
        case llmConfigName = "llm_config_name"
        case llmModel = "llm_model"
        case latencyMs = "latency_ms"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case costUSD = "cost_usd"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        threadID = try container.decodeIfPresent(Int.self, forKey: .threadID)
        roomID = try container.decodeIfPresent(Int64.self, forKey: .roomID)
        llmThreadID = try container.decodeIfPresent(Int.self, forKey: .llmThreadID)
        senderID = try container.decode(String.self, forKey: .senderID)
        senderUsername = try container.decode(String.self, forKey: .senderUsername)
        senderIcon = try container.decodeIfPresent(String.self, forKey: .senderIcon)
        messageType = try container.decodeIfPresent(String.self, forKey: .messageType) ?? "text"
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        failed = try container.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        streaming = try container.decodeIfPresent(Bool.self, forKey: .streaming) ?? false
        seq = try container.decodeIfPresent(Int64.self, forKey: .seq) ?? 0
        llmConfigID = try container.decodeIfPresent(Int.self, forKey: .llmConfigID)
        llmConfigName = try container.decodeIfPresent(String.self, forKey: .llmConfigName)
        llmModel = try container.decodeIfPresent(String.self, forKey: .llmModel)
        latencyMs = try container.decodeIfPresent(Int.self, forKey: .latencyMs)
        promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens)
        completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens)
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD)
    }
}

struct BotLLMThread: Decodable, Identifiable, Hashable {
    let id: Int
    let chatThreadID: Int
    let llmConfigID: Int?
    let configName: String?
    let configModel: String?
    let title: String

    enum CodingKeys: String, CodingKey {
        case id
        case chatThreadID = "chat_thread_id"
        case llmConfigID = "llm_config_id"
        case configName = "config_name"
        case configModel = "config_model"
        case title
    }
}

private struct ChatListResponse: Decodable { let chats: [ChatThread] }
private struct ChatMessageListResponse: Decodable { let messages: [ChatMessage] }
private struct SendMessageResponse: Decodable { let message: String; let id: Int }
private struct BotLLMThreadListResponse: Decodable {
    let threads: [BotLLMThread]
    let activeThread: BotLLMThread?
    enum CodingKeys: String, CodingKey { case threads; case activeThread = "active_thread" }
}

final class ChatService {
    private let apiClient = APIClient.shared

    func fetchChats(limit: Int = 50, offset: Int = 0, completion: @escaping (Result<[ChatThread], Error>) -> Void) {
        apiClient.requestDecodable(
            path: "/api/chats?limit=\(limit)&offset=\(offset)",
            errorDomain: "ChatService"
        ) { (result: Result<ChatListResponse, Error>) in
            completion(result.map { $0.chats })
        }
    }

    func fetchMessages(chatID: Int, limit: Int = 50, offset: Int = 0, llmThreadID: Int? = nil, since: String? = nil, completion: @escaping (Result<[ChatMessage], Error>) -> Void) {
        var path = "/api/chats/\(chatID)/messages?limit=\(limit)&offset=\(offset)"
        if let llmThreadID {
            path += "&llm_thread_id=\(llmThreadID)"
        }
        if let since,
           let encoded = since.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&since=\(encoded)"
        }
        apiClient.requestDecodable(
            path: path,
            errorDomain: "ChatService"
        ) { (result: Result<ChatMessageListResponse, Error>) in
            completion(result.map { $0.messages })
        }
    }

    func sendMessage(chatID: Int, content: String, llmThreadID: Int? = nil, completion: @escaping (Result<Int, Error>) -> Void) {
        var body: [String: Any] = ["content": content]
        if let llmThreadID {
            body["llm_thread_id"] = llmThreadID
        }
        apiClient.requestDecodable(
            path: "/api/chats/\(chatID)/messages",
            method: "POST",
            jsonBody: body,
            errorDomain: "ChatService"
        ) { (result: Result<SendMessageResponse, Error>) in
            completion(result.map { $0.id })
        }
    }

    /// Re-run the bot for a previous message. Server fans out the same
    /// streaming pipeline; new snapshots arrive via /ws/chat under a
    /// fresh chat_messages.id, so the row appears underneath without
    /// touching the original. Returns the newly-created message id.
    func retryMessage(chatID: Int, messageID: Int, completion: @escaping (Result<Int, Error>) -> Void) {
        apiClient.requestDecodable(
            path: "/api/chats/\(chatID)/messages/\(messageID)/retry",
            method: "POST",
            errorDomain: "ChatService"
        ) { (result: Result<SendMessageResponse, Error>) in
            completion(result.map { $0.id })
        }
    }

    func fetchBotLLMThreads(chatID: Int, completion: @escaping (Result<([BotLLMThread], BotLLMThread?), Error>) -> Void) {
        apiClient.requestDecodable(
            path: "/api/chats/\(chatID)/llm-threads",
            errorDomain: "ChatService"
        ) { (result: Result<BotLLMThreadListResponse, Error>) in
            completion(result.map { ($0.threads, $0.activeThread) })
        }
    }
}
