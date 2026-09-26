import Foundation

/// 服务端推来的实时消息
enum RealtimeMessage {
    case hello(latestSeq: Int, presence: [Presence])
    case event(EventRecord)
    case typing(conversationId: String, userId: String)
    case presence(Presence)
    case daju(conversationId: String, state: String, detail: String)
}

/// WebSocket 连接：断线自动重连（1、2、4……最多 30 秒），每 25 秒发一次心跳。
@MainActor
final class RealtimeClient {
    enum State { case disconnected, connecting, connected }

    private let api: APIClient
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    private var wanted = false
    private var focus: String?
    private(set) var state: State = .disconnected

    var onMessage: ((RealtimeMessage) -> Void)?
    var onStateChange: ((State) -> Void)?

    init(api: APIClient) {
        self.api = api
    }

    func connect() {
        wanted = true
        guard state == .disconnected, api.token != nil else { return }
        reconnectWork?.cancel()
        setState(.connecting)
        let session = URLSession(configuration: .default)
        var request = api.authorizedRequest(api.webSocketURL)
        request.timeoutInterval = 20
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
        receive(on: task)
    }

    func disconnect() {
        wanted = false
        reconnectWork?.cancel()
        teardown()
        setState(.disconnected)
    }

    private func teardown() {
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func setState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .failure:
                    self.handleDrop()
                case .success(let message):
                    if self.state != .connected {
                        self.setState(.connected)
                        self.reconnectAttempt = 0
                        self.startPing()
                        self.sendFocus()
                    }
                    if case .string(let text) = message { self.handle(text) }
                    self.receive(on: task)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8), let json = try? JSONDecoder().decode(JSONValue.self, from: data), let type = json["t"]?.stringValue else { return }
        switch type {
        case "hello":
            let presence = json["presence"]?.decode([Presence].self) ?? []
            onMessage?(.hello(latestSeq: Int(json["latestSeq"]?.doubleValue ?? 0), presence: presence))
        case "event":
            if let event = json["event"]?.decode(EventRecord.self) { onMessage?(.event(event)) }
        case "typing":
            if let conversation = json["conversationId"]?.stringValue, let user = json["userId"]?.stringValue {
                onMessage?(.typing(conversationId: conversation, userId: user))
            }
        case "presence":
            if let user = json["userId"]?.stringValue {
                onMessage?(.presence(Presence(userId: user, online: json["online"]?.boolValue ?? false, lastSeenAt: json["lastSeenAt"]?.doubleValue)))
            }
        case "daju":
            if let conversation = json["conversationId"]?.stringValue {
                onMessage?(.daju(conversationId: conversation, state: json["state"]?.stringValue ?? "idle", detail: json["detail"]?.stringValue ?? ""))
            }
        default:
            break
        }
    }

    private func handleDrop() {
        teardown()
        setState(.disconnected)
        guard wanted else { return }
        let delay = min(30, pow(2, Double(reconnectAttempt)))
        reconnectAttempt += 1
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.connect() }
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.send(["t": "ping"]) }
        }
    }

    private func send(_ object: [String: Any]) {
        guard state == .connected, let task, let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    /// 当前停在哪个会话（nil 表示没在看聊天）；服务端据此决定要不要推送
    func setFocus(_ conversationId: String?) {
        focus = conversationId
        sendFocus()
    }

    private func sendFocus() {
        let value: Any = focus.map { $0 as Any } ?? NSNull()
        send(["t": "focus", "conversationId": value])
    }

    func sendTyping(_ conversationId: String) {
        send(["t": "typing", "conversationId": conversationId])
    }

    /// 网络恢复或回到前台时立刻重连，不等退避
    func reconnectNow() {
        guard wanted, state == .disconnected else { return }
        reconnectAttempt = 0
        connect()
    }
}
