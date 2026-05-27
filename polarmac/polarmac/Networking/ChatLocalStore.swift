import Foundation

final class ChatLocalStore {
    static let shared = ChatLocalStore()

    private let baseDir: URL
    private let queue = DispatchQueue(label: "ChatLocalStore.write", qos: .utility)
    private var pendingWrites: [String: DispatchWorkItem] = [:]
    private let writeDebounce: TimeInterval = 0.4
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "polarmac"
        baseDir = caches.appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    private func key(chatID: Int, threadID: Int?) -> String {
        if let threadID { return "\(chatID)_\(threadID)" }
        return "\(chatID)"
    }

    private func fileURL(chatID: Int, threadID: Int?) -> URL {
        baseDir.appendingPathComponent("\(key(chatID: chatID, threadID: threadID)).json")
    }

    func load(chatID: Int, threadID: Int? = nil) -> [ChatMessage]? {
        let url = fileURL(chatID: chatID, threadID: threadID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode([ChatMessage].self, from: data)
    }

    func save(chatID: Int, threadID: Int? = nil, messages: [ChatMessage]) {
        let snapshot = messages
        let k = key(chatID: chatID, threadID: threadID)
        let url = fileURL(chatID: chatID, threadID: threadID)
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingWrites[k]?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingWrites[k] = nil
                guard let data = try? self.encoder.encode(snapshot) else { return }
                try? data.write(to: url, options: .atomic)
            }
            self.pendingWrites[k] = item
            self.queue.asyncAfter(deadline: .now() + self.writeDebounce, execute: item)
        }
    }

    func flush(chatID: Int, threadID: Int? = nil) {
        let k = key(chatID: chatID, threadID: threadID)
        queue.sync {
            if let pending = pendingWrites[k] {
                pending.perform()
                pending.cancel()
                pendingWrites[k] = nil
            }
        }
    }
}
