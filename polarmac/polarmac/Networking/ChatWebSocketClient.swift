import Foundation

enum ChatWebSocketConnectionState: Equatable {
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case disconnected
}

struct ChatWebSocketEvent: Decodable {
    let type: String
    let chatID: Int?
    let roomID: Int64?
    let message: ChatMessage?
    let messageID: Int?
    let userID: String?
    let readAt: String?
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case type
        case chatID = "chat_id"
        case roomID = "room_id"
        case message
        case messageID = "message_id"
        case userID = "user_id"
        case readAt = "read_at"
        case deletedAt = "deleted_at"
    }
}

protocol ChatWebSocketClientDelegate: AnyObject {
    func chatWebSocketClient(_ client: ChatWebSocketClient, didReceive event: ChatWebSocketEvent)
    func chatWebSocketClient(_ client: ChatWebSocketClient, didChangeState state: ChatWebSocketConnectionState)
}

final class ChatWebSocketClient {
    weak var delegate: ChatWebSocketClientDelegate?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var heartbeatTimer: Timer?
    private var reconnectWorkItem: DispatchWorkItem?
    private var shouldReconnect = false
    private var reconnectAttempt = 0
    private var connectionGeneration = 0
    private var state: ChatWebSocketConnectionState = .disconnected {
        didSet {
            guard state != oldValue else { return }
            delegate?.chatWebSocketClient(self, didChangeState: state)
        }
    }

    func connect() {
        runOnMain { [weak self] in
            guard let self else { return }
            self.disconnect(shouldNotify: false)
            self.shouldReconnect = true
            self.reconnectAttempt = 0
            self.openConnection(isReconnect: false)
        }
    }

    func disconnect() {
        runOnMain { [weak self] in
            self?.disconnect(shouldNotify: true)
        }
    }

    private func openConnection(isReconnect: Bool) {
        guard let baseURL = AppEnvironment.apiBaseURL(),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            state = .disconnected
            return
        }

        components.path = "/ws/chat"
        components.query = nil
        switch components.scheme {
        case "https": components.scheme = "wss"
        default: components.scheme = "ws"
        }

        guard let wsURL = components.url else { return }

        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        connectionGeneration += 1
        let generation = connectionGeneration

        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = HTTPCookieStorage.shared
        // Same fail-fast budget as APIClient; defaults of 60s hang the
        // connection indicator far longer than the user expects on a
        // typo'd base URL.
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 30

        let session = URLSession(configuration: config)
        self.session = session

        // X-Workspace-Id needs the URLRequest overload — the URL-only
        // overload skips custom headers, leaving the WS hub on the
        // server to pin us to the personal team.
        var wsRequest = URLRequest(url: wsURL)
        if let workspaceID = AppEnvironment.currentWorkspaceID {
            wsRequest.setValue(workspaceID, forHTTPHeaderField: "X-Workspace-Id")
        }

        let task = session.webSocketTask(with: wsRequest)
        self.task = task
        state = isReconnect ? .reconnecting(attempt: reconnectAttempt) : .connecting
        task.resume()
        state = .connected
        startHeartbeat()
        listen(generation: generation)
    }

    private func disconnect(shouldNotify: Bool) {
        shouldReconnect = false
        connectionGeneration += 1
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if shouldNotify {
            state = .disconnected
        }
    }

    private func listen(generation: Int) {
        task?.receive { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.connectionGeneration == generation else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.listen(generation: generation)
                case .failure(let error):
                    self.handleConnectionLoss(error: error)
                }
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
        heartbeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func sendPing() {
        task?.sendPing { [weak self] error in
            guard let self, let error else { return }
            DispatchQueue.main.async {
                self.handleConnectionLoss(error: error)
            }
        }
    }

    private func handleConnectionLoss(error: Error?) {
        guard shouldReconnect else { return }
        guard reconnectWorkItem == nil else { return }
        cleanupCurrentConnection()
        reconnectAttempt += 1
        state = .reconnecting(attempt: reconnectAttempt)

        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 30.0)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.shouldReconnect else { return }
            self.openConnection(isReconnect: true)
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cleanupCurrentConnection() {
        connectionGeneration += 1
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let payload: Data?
        switch message {
        case .data(let data): payload = data
        case .string(let text): payload = text.data(using: .utf8)
        @unknown default: payload = nil
        }

        guard let payload else { return }
        guard let event = try? JSONDecoder().decode(ChatWebSocketEvent.self, from: payload) else { return }

        DispatchQueue.main.async {
            self.delegate?.chatWebSocketClient(self, didReceive: event)
        }
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
