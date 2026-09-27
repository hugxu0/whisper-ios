import Foundation
import Network

/// 服务端推来的实时消息
enum RealtimeMessage {
    case hello(latestSeq: Int, presence: [Presence])
    case event(EventRecord)
    case typing(conversationId: String, userId: String)
    case presence(Presence)
    case daju(conversationId: String, state: String, detail: String)
}

/// WebSocket 连接：断线自动重连（1、2、4……最多 30 秒）。
/// 每 25 秒发一次心跳，10 秒内没回应就当连接已经死了、马上重连；网络切换（Wi‑Fi 和蜂窝）时也立刻重连，
/// 不然旧连接可能一直“看起来连着”却收不到任何消息。
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
    private var awaitingPong = false
    private let pathMonitor = NWPathMonitor()
    private var lastPath: String?
    private(set) var state: State = .disconnected

    var onMessage: ((RealtimeMessage) -> Void)?
    var onStateChange: ((State) -> Void)?

    init(api: APIClient) {
        self.api = api
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status)|\(path.availableInterfaces.map(\.name).joined(separator: ","))"
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(signature, satisfied: satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "whisper.network"))
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
        awaitingPong = false
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
            Task { @MainActor in self?.verify() }
        }
    }

    /// 发一次心跳确认连接还活着；10 秒内没有回应就断开重连。发出的消息迟迟没确认时也会调用
    func verify() {
        guard state == .connected, let task, !awaitingPong else { return }
        awaitingPong = true
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                self.awaitingPong = false
                if error != nil { self.handleDrop() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            Task { @MainActor in
                guard let self, self.task === task, self.awaitingPong else { return }
                self.awaitingPong = false
                self.handleDrop()
            }
        }
    }

    /// 网络换了：旧连接多半已经不通，直接重连
    private func networkChanged(_ signature: String, satisfied: Bool) {
        let previous = lastPath
        lastPath = signature
        guard let previous, previous != signature, wanted else { return }
        teardown()
        setState(.disconnected)
        guard satisfied else { return }
        reconnectAttempt = 0
        reconnectWork?.cancel()
        connect()
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
