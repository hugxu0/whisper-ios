import Foundation
import Observation
import UIKit

/// 还没被服务端确认的消息（发送中、上传中、失败）
struct OutgoingMessage: Identifiable, Hashable {
    let id: String
    let conversationId: String
    var kind: String
    var text: String
    var replyTo: ReplyPreview?
    var media: [MessageMedia]
    var mediaIds: [String] = []
    var waveform: [Double]?
    var stickerId: String?
    var interaction: String?
    var failed = false
    var progress: Double?
    let createdAt: Double

    func asMessage(senderId: String) -> Message {
        var payload = MessagePayload()
        payload.media = media
        payload.waveform = waveform
        payload.stickerId = stickerId
        payload.interaction = interaction
        return Message(
            id: id, conversationId: conversationId, seq: Int.max, senderId: senderId, kind: kind, text: text,
            payload: payload, replyTo: replyTo, reactions: [], createdAt: createdAt, editedAt: nil, recalledAt: nil
        )
    }
}

/// 准备好上传的本地媒体
struct PreparedMedia {
    let localId: String
    let fileURL: URL
    let filename: String
    let meta: UploadMeta
    let thumbnail: Data?
    /// 发出去之前就能显示的预览图（写进缓存，气泡直接用）
    let preview: UIImage?
}

/// 一个会话的消息窗口：连续的一段消息（按 seq 升序），可以往前、往后加载，或跳到某条/某天。
/// 窗口包含最新消息时（hasNewer == false）实时追加新消息。
@Observable
@MainActor
final class ChatModel {
    enum Change: Equatable {
        case reset(anchor: String?)
        case prepended
        /// 新消息（自己发的或实时收到的）
        case appended
        /// 往后翻页加载的一页历史，不是新消息：保持位置，不自动滚到底
        case pageAppended
        case updated
    }

    /// 翻页每次加载的条数
    static let pageSize = 80

    let conversationId: String
    @ObservationIgnored unowned let app: AppModel

    private(set) var messages: [Message] = []
    private(set) var outgoing: [OutgoingMessage] = []
    private(set) var hasOlder = true
    private(set) var hasNewer = false
    private(set) var loadedOnce = false
    private(set) var isLoadingOlder = false
    private(set) var isLoadingNewer = false
    /// 每次变化加一，UIKit 页面据此刷新
    private(set) var version = 0
    @ObservationIgnored private(set) var lastChange: Change = .reset(anchor: nil)
    @ObservationIgnored var onChange: ((Change) -> Void)?
    /// 跳转的目标消息：聊天页还没显示时先记下，显示出来后滚到这里
    @ObservationIgnored var pendingAnchor: String?
    /// 每次整页加载（最新 / 跳转）加一；旧请求回来时已经过时，直接丢掉
    @ObservationIgnored private var windowToken = 0
    @ObservationIgnored private var windowLoads = 0
    /// 跳到历史位置时留一份最新的一段，实时消息继续往里加；点“回到最新”时直接换回来，不用等网络
    @ObservationIgnored private var liveTail: [Message] = []
    /// 上传中的媒体消息：每个文件各自的进度
    @ObservationIgnored private var uploadFractions: [String: [Double]] = [:]

    init(conversationId: String, app: AppModel) {
        self.conversationId = conversationId
        self.app = app
    }

    var isLive: Bool { !hasNewer }

    /// 显示用：已确认的消息 + 待发送的消息
    var displayMessages: [Message] {
        guard let me = app.me?.id else { return messages }
        return hasNewer ? messages : messages + outgoing.map { $0.asMessage(senderId: me) }
    }

    func outgoingState(_ id: String) -> OutgoingMessage? {
        outgoing.first { $0.id == id }
    }

    private func notify(_ change: Change) {
        lastChange = change
        version += 1
        onChange?(change)
        if isLive { app.scheduleSave() }
    }

    // MARK: - 加载

    func restore(_ cached: [Message]) {
        messages = cached
        hasOlder = true
        hasNewer = false
        notify(.reset(anchor: nil))
    }

    func snapshotForCache() -> [Message] {
        Array((isLive ? messages : liveTail).suffix(80))
    }

    private func fetch(_ query: [String: String?]) async throws -> MessagePage {
        var query = query
        query["limit"] = query["limit"] ?? String(Self.pageSize)
        return try await app.api.get("v1/conversations/\(conversationId)/messages", query: query)
    }

    /// 整页替换消息窗口；期间又发起了新的整页加载，就丢掉这次的结果
    private func loadWindow(_ query: [String: String?], anchor: (MessagePage) -> String?) async {
        windowToken += 1
        let token = windowToken
        windowLoads += 1
        defer { windowLoads -= 1 }
        guard let page = try? await fetch(query), token == windowToken else { return }
        if page.hasNewer, isLive, !messages.isEmpty {
            liveTail = Array(messages.suffix(160))
        } else if !page.hasNewer {
            liveTail = []
        }
        messages = page.messages
        hasOlder = page.hasOlder
        hasNewer = page.hasNewer
        loadedOnce = true
        let target = anchor(page)
        pendingAnchor = target
        notify(.reset(anchor: target))
    }

    func loadLatest() async {
        await loadWindow([:]) { _ in nil }
    }

    /// 首次进入时：有缓存先显示缓存，再拉最新一页；正在跳转时不打断
    func ensureLoaded() async {
        if !loadedOnce, windowLoads == 0 { await loadLatest() }
    }

    /// 重新连上后：窗口是最新的一段就把错过的消息合并进来，不打断正在看的位置
    func reloadIfLive() async {
        guard loadedOnce || !messages.isEmpty, isLive else { return }
        await refreshTail()
    }

    /// 拉最新一页，和现在的窗口有重叠就合并（只追加、更新），接不上才整页替换
    private func refreshTail() async {
        let token = windowToken
        guard let page = try? await fetch([:]), token == windowToken, isLive else { return }
        guard let last = messages.last, let first = page.messages.first, first.seq <= last.seq else {
            messages = page.messages
            hasOlder = page.hasOlder
            loadedOnce = true
            notify(.reset(anchor: nil))
            return
        }
        loadedOnce = true
        var appended = false
        var updated = false
        for message in page.messages {
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                if messages[index] != message {
                    messages[index] = message
                    updated = true
                }
            } else if message.seq > (messages.last?.seq ?? 0) {
                messages.append(message)
                appended = true
            } else if let head = messages.first, message.seq > head.seq {
                insertSorted(message)
                updated = true
            }
        }
        let confirmed = outgoing.filter { item in messages.contains { $0.id == item.id } }
        if !confirmed.isEmpty {
            outgoing.removeAll { item in confirmed.contains { $0.id == item.id } }
            updated = true
        }
        if appended { notify(.appended) } else if updated { notify(.updated) }
    }

    func loadOlder() async {
        guard hasOlder, !isLoadingOlder, let first = messages.first else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let token = windowToken
        guard let page = try? await fetch(["before": String(first.seq)]), token == windowToken else { return }
        let known = Set(messages.map(\.id))
        messages = page.messages.filter { !known.contains($0.id) } + messages
        hasOlder = page.hasOlder
        notify(.prepended)
    }

    func loadNewer() async {
        guard hasNewer, !isLoadingNewer, let last = messages.last else { return }
        isLoadingNewer = true
        defer { isLoadingNewer = false }
        let token = windowToken
        guard let page = try? await fetch(["after": String(last.seq)]), token == windowToken else { return }
        let known = Set(messages.map(\.id))
        messages += page.messages.filter { !known.contains($0.id) }
        hasNewer = page.hasNewer
        if !hasNewer { liveTail = [] }
        notify(.pageAppended)
    }

    func jump(to messageId: String) async {
        if loadedOnce, messages.contains(where: { $0.id == messageId }) {
            pendingAnchor = messageId
            notify(.reset(anchor: messageId))
            return
        }
        await loadWindow(["around": messageId, "limit": "100"]) { _ in messageId }
    }

    func jump(toDay day: String) async {
        await loadWindow(["date": day, "limit": "100"]) { $0.messages.first?.id }
    }

    /// 回到最新：留着最新的一段就立刻换回来，再在后台补齐；没有才整页加载
    func jumpToLatest() async {
        if isLive {
            notify(.reset(anchor: nil))
        } else if !liveTail.isEmpty {
            windowToken += 1
            messages = liveTail
            liveTail = []
            hasOlder = true
            hasNewer = false
            pendingAnchor = nil
            notify(.reset(anchor: nil))
            await refreshTail()
        } else {
            await loadLatest()
        }
    }

    // MARK: - 实时更新

    func upsert(_ message: Message) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
            notify(.updated)
            return
        }
        if let index = outgoing.firstIndex(where: { $0.id == message.id }) {
            outgoing.remove(at: index)
            if isLive { insertSorted(message) } else if let tailLast = liveTail.last, message.seq > tailLast.seq { liveTail.append(message) }
            notify(.updated)
            return
        }
        guard loadedOnce || !messages.isEmpty else { return }
        if !isLive {
            // 在看历史：新消息先记进最新的那一段
            if let index = liveTail.firstIndex(where: { $0.id == message.id }) {
                liveTail[index] = message
            } else if let tailLast = liveTail.last, message.seq > tailLast.seq {
                liveTail.append(message)
            }
        }
        if isLive, message.seq > (messages.last?.seq ?? 0) {
            messages.append(message)
            notify(.appended)
        } else if let first = messages.first, let last = messages.last, message.seq > first.seq, isLive || message.seq < last.seq {
            insertSorted(message)
            notify(.updated)
        }
    }

    private func insertSorted(_ message: Message) {
        let index = messages.firstIndex { $0.seq > message.seq } ?? messages.count
        messages.insert(message, at: index)
    }

    func readStatesChanged() {
        notify(.updated)
    }

    /// 对方读到的位置（大橘私聊里没有“对方”）
    var partnerReadSeq: Int {
        guard let partner = app.partner?.id else { return 0 }
        return app.readSeq(conversationId, userId: partner)
    }

    func markReadIfNeeded() {
        guard isLive, let last = messages.last else { return }
        app.markRead(conversationId, seq: last.seq)
    }

    // MARK: - 发送

    func sendText(_ text: String, replyTo: Message?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        enqueue(OutgoingMessage(id: IDs.message(), conversationId: conversationId, kind: "text", text: trimmed, replyTo: preview(replyTo), media: [], createdAt: Date().timeIntervalSince1970 * 1000))
    }

    func sendSticker(_ sticker: Sticker) {
        var message = OutgoingMessage(id: IDs.message(), conversationId: conversationId, kind: "sticker", text: "", replyTo: nil, media: [sticker.media], createdAt: Date().timeIntervalSince1970 * 1000)
        message.mediaIds = [sticker.media.id]
        message.stickerId = sticker.id
        enqueue(message)
    }

    func sendInteraction(_ interaction: String, note: String = "") {
        var message = OutgoingMessage(id: IDs.message(), conversationId: conversationId, kind: "interaction", text: note, replyTo: nil, media: [], createdAt: Date().timeIntervalSince1970 * 1000)
        message.interaction = interaction
        enqueue(message)
        app.playInteraction(interaction)
    }

    /// 图片、视频、语音、文件：先显示本地预览，上传完再发消息
    func sendMedia(_ items: [PreparedMedia], kind: String, waveform: [Double]? = nil, replyTo: Message? = nil) {
        guard !items.isEmpty else { return }
        let placeholders = items.map { item in
            MessageMedia(
                id: item.localId, kind: item.meta.kind, mime: item.meta.mime, size: 0, width: item.meta.width,
                height: item.meta.height, durationMs: item.meta.durationMs, name: item.meta.name, hasThumb: false
            )
        }
        for item in items {
            if let preview = item.preview, let data = preview.jpegData(compressionQuality: 0.8) {
                MediaCache.shared.store(data, id: item.localId, thumb: false)
            }
        }
        var message = OutgoingMessage(id: IDs.message(), conversationId: conversationId, kind: kind, text: "", replyTo: preview(replyTo), media: placeholders, createdAt: Date().timeIntervalSince1970 * 1000)
        message.waveform = waveform
        message.progress = 0
        outgoing.append(message)
        notify(.appended)
        Task { await upload(items, for: message.id) }
    }

    /// 最多同时传 3 个，进度取平均
    private func upload(_ items: [PreparedMedia], for id: String) async {
        do {
            var tasks: [Task<MediaInfo, Error>] = []
            for (index, item) in items.enumerated() {
                if index >= 3 { _ = try? await tasks[index - 3].value }
                tasks.append(Task { try await self.uploadOne(item, index: index, count: items.count, messageId: id) })
            }
            var uploaded: [MediaInfo] = []
            for task in tasks { uploaded.append(try await task.value) }
            uploadFractions[id] = nil
            updateOutgoing(id) {
                $0.mediaIds = uploaded.map(\.id)
                $0.progress = nil
            }
            if let message = outgoing.first(where: { $0.id == id }) { await deliver(message) }
        } catch {
            uploadFractions[id] = nil
            updateOutgoing(id) {
                $0.failed = true
                $0.progress = nil
            }
        }
        for item in items { try? FileManager.default.removeItem(at: item.fileURL) }
    }

    private func uploadOne(_ item: PreparedMedia, index: Int, count: Int, messageId: String) async throws -> MediaInfo {
        let media = try await app.api.upload(meta: item.meta, file: item.fileURL, filename: item.filename, thumb: item.thumbnail) { [weak self] value in
            self?.setUploadProgress(messageId, index: index, count: count, value: value)
        }
        // 本地文件直接放进缓存，发出后不用再下载
        if let data = try? Data(contentsOf: item.fileURL) { MediaCache.shared.store(data, id: media.id, thumb: false) }
        if let thumb = item.thumbnail { MediaCache.shared.store(thumb, id: media.id, thumb: true) }
        return media
    }

    private func setUploadProgress(_ id: String, index: Int, count: Int, value: Double) {
        var fractions = uploadFractions[id] ?? Array(repeating: 0, count: count)
        guard index < fractions.count else { return }
        fractions[index] = value
        uploadFractions[id] = fractions
        let overall = fractions.reduce(0, +) / Double(count)
        updateOutgoing(id) { $0.progress = overall }
    }

    private func preview(_ message: Message?) -> ReplyPreview? {
        guard let message else { return nil }
        return ReplyPreview(id: message.id, senderId: message.senderId, kind: message.kind, text: MessagePreview.text(message, app: app), recalled: message.isRecalled)
    }

    private func enqueue(_ message: OutgoingMessage) {
        if hasNewer { Task { await jumpToLatest() } }
        outgoing.append(message)
        notify(.appended)
        Task { await deliver(message) }
    }

    private func updateOutgoing(_ id: String, _ change: (inout OutgoingMessage) -> Void) {
        guard let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        change(&outgoing[index])
        notify(.updated)
    }

    private func deliver(_ message: OutgoingMessage) async {
        var body: [String: Any] = ["id": message.id, "conversationId": conversationId, "kind": message.kind, "text": message.text]
        if !message.mediaIds.isEmpty { body["mediaIds"] = message.mediaIds }
        if let reply = message.replyTo { body["replyToId"] = reply.id }
        if let waveform = message.waveform { body["waveform"] = waveform }
        if let sticker = message.stickerId { body["stickerId"] = sticker }
        if let interaction = message.interaction { body["interaction"] = interaction }
        do {
            struct Response: Decodable { let message: Message }
            let response: Response = try await app.api.post("v1/messages", body)
            upsert(response.message)
            var summary = app.conversations[conversationId]
            if summary != nil, response.message.seq >= (summary?.lastMessage?.seq ?? 0) {
                summary?.lastMessage = response.message
                app.conversations[conversationId] = summary
            }
        } catch {
            updateOutgoing(message.id) { $0.failed = true }
        }
    }

    func retry(_ id: String) {
        guard let message = outgoing.first(where: { $0.id == id }), message.failed else { return }
        updateOutgoing(id) { $0.failed = false }
        if message.media.isEmpty || !message.mediaIds.isEmpty {
            Task { await deliver(message) }
        } else {
            // 上传没完成的媒体消息没法重试（本地文件已清理），直接移除
            discard(id)
        }
    }

    func discard(_ id: String) {
        outgoing.removeAll { $0.id == id }
        notify(.updated)
    }

    /// 重新连上后补发失败的文字消息
    func retryFailed() {
        for message in outgoing where message.failed && (message.media.isEmpty || !message.mediaIds.isEmpty) {
            retry(message.id)
        }
    }

    // MARK: - 编辑、撤回、回应

    private struct MessageResponse: Decodable { let message: Message }

    func edit(_ message: Message, text: String) async throws {
        let response: MessageResponse = try await app.api.patch("v1/messages/\(message.id)", ["text": text])
        upsert(response.message)
    }

    func recall(_ message: Message) async throws {
        let response: MessageResponse = try await app.api.post("v1/messages/\(message.id)/recall")
        upsert(response.message)
    }

    func react(_ message: Message, emoji: String?) {
        guard let me = app.me?.id, let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        // 先本地改，接口结果回来再覆盖
        var updated = messages[index]
        updated.reactions.removeAll { $0.userId == me }
        if let emoji { updated.reactions.append(Reaction(userId: me, emoji: emoji)) }
        messages[index] = updated
        notify(.updated)
        Task {
            let body: [String: Any] = ["emoji": emoji.map { $0 as Any } ?? NSNull()]
            if let response: MessageResponse = try? await app.api.put("v1/messages/\(message.id)/reaction", body) {
                upsert(response.message)
            }
        }
    }

    func toggleHeart(_ message: Message) {
        let mine = message.reactions.first { $0.userId == app.me?.id }
        react(message, emoji: mine?.emoji == "❤️" ? nil : "❤️")
    }

    func transcribe(_ message: Message) async {
        if let response: MessageResponse = try? await app.api.post("v1/messages/\(message.id)/transcribe") {
            upsert(response.message)
        }
    }
}
