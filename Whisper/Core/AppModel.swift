import Foundation
import Observation
import UIKit
import UserNotifications

struct DajuActivity: Equatable {
    var state: String
    var detail: String
}

struct Banner: Identifiable, Equatable {
    let id = UUID()
    let conversationId: String
    let senderId: String
    let title: String
    let body: String
}

struct InteractionEffectRequest: Identifiable, Equatable {
    let id = UUID()
    let interaction: String
    let fromMe: Bool
}

private struct CacheSnapshot: Codable {
    var me: User
    var users: [User]
    var conversations: [ConversationSummary]
    var settings: SettingsBag
    var stickers: [Sticker]
    var stickerGroups: [StickerGroup]?
    var features: Features
    var lastSeq: Int
    var recent: [String: [Message]]
}

/// 全局状态：登录、用户、会话、设置、实时同步。各页面从这里读数据，改动也从这里发出去。
@Observable
@MainActor
final class AppModel {
    enum Phase: Equatable { case launching, loggedOut, syncing, ready }

    var phase: Phase = .launching
    let api: APIClient
    @ObservationIgnored let realtime: RealtimeClient

    var me: User?
    var users: [String: User] = [:]
    var presence: [String: Presence] = [:]
    var conversations: [String: ConversationSummary] = [:]
    var settings = SettingsBag(shared: [:], mine: [:])
    var stickers: [Sticker] = []
    var stickerGroups: [StickerGroup] = []
    var features = Features(daju: false, transcribe: false)
    var typing: [String: Date] = [:]
    var dajuActivity: [String: DajuActivity] = [:]
    var connection: RealtimeClient.State = .disconnected
    var banner: Banner?
    var openConversationRequest: String?
    var interactionEffect: InteractionEffectRequest?
    /// 深链或横幅要求切换的标签页
    var tabRequest: String?
    /// 深链要求打开的子页面（whisper://page/<名字>），由它所在标签页的根视图取走
    var pageRequest: String?
    /// 推送里点开的相册（whisper://album/<id>），“我们”页取走
    var albumRequest: String?
    /// 相册里对方的新动态和新评论（“我们”标签上的数字）
    var albumUnread = 0
    @ObservationIgnored private var launchRouteOpened = false
    /// 每类事件的计数，功能页面观察它来刷新（计划、纪念日、宠物、卡牌……）
    var revision: [String: Int] = [:]
    var focusedConversation: String? {
        didSet { if oldValue != focusedConversation { realtime.setFocus(focusedConversation) } }
    }

    @ObservationIgnored private(set) var chats: [String: ChatModel] = [:]
    @ObservationIgnored private(set) var lastSeq = 0
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var catchingUp = false
    /// 补拉进行中又要求补拉（比如又收到了跳号的事件）：这一轮结束后再拉一遍，不丢事件
    @ObservationIgnored private var catchUpAgain = false
    @ObservationIgnored private var prefetched = false
    @ObservationIgnored private var albumRefresh: Task<Void, Never>?
    @ObservationIgnored private var bannerWork: DispatchWorkItem?
    @ObservationIgnored private var appActive = true
    @ObservationIgnored private var activeSince = Date()
    /// 这一轮补拉到的新消息要不要弹横幅：App 一直开着、只是连接断了一会儿时要（服务端以为 App 开着，没推 Bark）
    @ObservationIgnored private var announceCatchUp = false

    init() {
        api = APIClient(baseURL: APIClient.defaultBaseURL)
        realtime = RealtimeClient(api: api)
        MediaCache.shared.api = api
        api.onUnauthorized = { [weak self] in
            Task { @MainActor in self?.handleUnauthorized() }
        }
        realtime.onMessage = { [weak self] message in self?.handle(message) }
        realtime.onStateChange = { [weak self] state in self?.connection = state }

        if let token = Keychain.get("token") {
            api.token = token
            if let cache = LocalCache.load(CacheSnapshot.self, from: "snapshot") {
                restore(cache)
                phase = .ready
                realtime.connect()
                openLaunchRoute()
            } else {
                phase = .syncing
                Task { await initialSync() }
            }
        } else {
            phase = .loggedOut
        }
    }

    // MARK: - 常用查询

    var partner: User? { users.values.first { $0.kind == "human" && $0.id != me?.id } }
    var daju: User? { users["daju"] }
    var myDajuConversationId: String { "daju-\(me?.id ?? "")" }

    func user(_ id: String) -> User? { users[id] }

    /// 对方的备注名优先
    func displayName(_ userId: String) -> String {
        if userId == me?.id { return "我" }
        if userId == partner?.id, let alias = settings.mine["partnerAlias"]?.stringValue, !alias.isEmpty { return alias }
        return users[userId]?.displayName ?? "未知"
    }

    func name(_ userId: String) -> String {
        if userId == partner?.id, let alias = settings.mine["partnerAlias"]?.stringValue, !alias.isEmpty { return alias }
        return users[userId]?.displayName ?? "未知"
    }

    var totalUnread: Int { conversations.values.reduce(0) { $0 + $1.unreadCount } }
    /// 聊天标签上的数字只算情侣聊天；和大橘的私聊算在大橘那边
    var coupleUnread: Int { conversations["couple"]?.unreadCount ?? 0 }
    var dajuUnread: Int { conversations[myDajuConversationId]?.unreadCount ?? 0 }

    func isTyping(_ conversationId: String) -> Bool {
        guard let until = typing[conversationId] else { return false }
        return until > Date()
    }

    func chat(_ conversationId: String) -> ChatModel {
        if let chat = chats[conversationId] { return chat }
        let chat = ChatModel(conversationId: conversationId, app: self)
        chats[conversationId] = chat
        return chat
    }

    // MARK: - 登录

    func login(username: String, password: String) async throws {
        let body: [String: Any] = [
            "username": username,
            "password": password,
            "deviceName": UIDevice.current.name,
            "platform": "ios",
            "appVersion": APIClient.appVersion,
        ]
        let response: LoginResponse = try await api.post("v1/auth/login", body)
        Keychain.set(response.token, for: "token")
        api.token = response.token
        me = response.user
        phase = .syncing
        await initialSync()
        // 自动化截图时不弹系统权限框
        if UserDefaults.standard.string(forKey: "autologin") == nil { requestNotificationPermission() }
    }

    private func initialSync() async {
        do {
            try await bootstrap()
            phase = .ready
            realtime.connect()
            openLaunchRoute()
        } catch APIError.unauthorized {
            handleUnauthorized()
        } catch {
            // 有令牌但暂时连不上：稍后重试
            try? await Task.sleep(for: .seconds(3))
            if phase == .syncing { await initialSync() }
        }
    }

    func logout() {
        let api = self.api
        Task { try? await api.send("POST", "v1/auth/logout") }
        clearSession()
    }

    private func handleUnauthorized() {
        guard phase != .loggedOut else { return }
        clearSession()
    }

    private func clearSession() {
        realtime.disconnect()
        Keychain.set(nil, for: "token")
        LocalCache.clear()
        ResponseCache.shared.clear()
        api.token = nil
        chats = [:]
        me = nil
        users = [:]
        conversations = [:]
        stickers = []
        stickerGroups = []
        lastSeq = 0
        prefetched = false
        phase = .loggedOut
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge, .alert, .sound]) { _, _ in }
    }

    // MARK: - 同步

    func bootstrap() async throws {
        let data: Bootstrap = try await api.get("v1/bootstrap")
        me = data.me
        users = Dictionary(uniqueKeysWithValues: data.users.map { ($0.id, $0) })
        for entry in data.presence { presence[entry.userId] = entry }
        conversations = Dictionary(uniqueKeysWithValues: data.conversations.map { ($0.id, $0) })
        settings = data.settings
        stickers = data.stickers
        stickerGroups = data.stickerGroups ?? []
        features = data.features
        lastSeq = data.latestSeq
        for chat in chats.values { await chat.reloadIfLive() }
        for key in revision.keys { revision[key, default: 0] += 1 }
        scheduleSave()
    }

    /// 按序号补拉错过的事件；落后太多时直接重新 bootstrap
    func catchUp() async {
        guard !catchingUp else {
            catchUpAgain = true
            return
        }
        catchingUp = true
        defer { catchingUp = false }
        repeat {
            catchUpAgain = false
            do {
                var more = true
                while more {
                    let page: EventPage = try await api.get("v1/events", query: ["after": String(lastSeq), "limit": "500"])
                    for event in page.events { apply(event) }
                    more = page.hasMore
                    if page.events.isEmpty { break }
                }
            } catch {
                // 下次连接时再补
                return
            }
        } while catchUpAgain
    }

    /// 连上以后：补发之前没发出去的消息，还在“发送中”的去服务端核对一下
    private func resumeOutgoing() {
        for chat in chats.values {
            chat.retryFailed()
            Task { await chat.confirmPending() }
        }
    }

    /// 重新算相册的未读数；相册事件往往一连好几条，等一下再拉
    func refreshAlbumUnread(after delay: Double = 0) {
        albumRefresh?.cancel()
        albumRefresh = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            struct AlbumList: Decodable { let albums: [Album] }
            if let list: AlbumList = try? await api.get("v1/albums", cache: true) { setAlbums(list.albums) }
        }
    }

    func setAlbums(_ albums: [Album]) {
        albumUnread = albums.reduce(0) { $0 + $1.unread }
    }

    /// 启动后在后台把各个页面的数据先拉一遍存进缓存，第一次点开时也不用等
    private func prefetchPages() {
        guard !prefetched else { return }
        prefetched = true
        let api = self.api
        Task {
            try? await Task.sleep(for: .seconds(4))
            refreshAlbumUnread()
            let paths = ["v1/together", "v1/anniversaries", "v1/plans", "v1/wishes", "v1/capsules", "v1/pet", "v1/cards"]
            for path in paths where (ResponseCache.shared.age(for: path) ?? .infinity) > 120 {
                if let data = try? await api.send("GET", path) { ResponseCache.shared.store(data, for: path) }
            }
            let diary = ResponseCache.key("v1/daju/diaries", query: ["limit": "1"])
            if (ResponseCache.shared.age(for: diary) ?? .infinity) > 600,
               let data = try? await api.send("GET", "v1/daju/diaries", query: ["limit": "1"]) {
                ResponseCache.shared.store(data, for: diary)
            }
        }
    }

    private func handle(_ message: RealtimeMessage) {
        switch message {
        case .hello(let latest, let entries):
            for entry in entries { presence[entry.userId] = entry }
            Task {
                if lastSeq > 0 && latest - lastSeq <= 3000 {
                    // 刚回到前台时补拉到的不再提示（在后台时 Bark 已经推过了）
                    announceCatchUp = appActive && Date().timeIntervalSince(activeSince) > 5
                    await catchUp()
                    announceCatchUp = false
                } else {
                    try? await bootstrap()
                }
                resumeOutgoing()
                prefetchPages()
            }
        case .event(let event):
            if lastSeq > 0 && event.seq > lastSeq + 1 {
                Task { await catchUp() }
            } else {
                apply(event)
            }
        case .typing(let conversationId, let userId):
            if userId != me?.id { typing[conversationId] = Date().addingTimeInterval(5) }
        case .presence(let entry):
            presence[entry.userId] = entry
        case .daju(let conversationId, let state, let detail):
            dajuActivity[conversationId] = state == "idle" ? nil : DajuActivity(state: state, detail: detail)
        }
    }

    func apply(_ event: EventRecord) {
        guard event.seq > lastSeq else { return }
        lastSeq = event.seq
        switch event.kind {
        case "message":
            if let message = event.payload["message"]?.decode(Message.self) { receive(message, live: !catchingUp) }
        case "read":
            if let conversationId = event.payload["conversationId"]?.stringValue,
               let userId = event.payload["userId"]?.stringValue,
               let seq = event.payload["seq"]?.doubleValue {
                applyRead(conversationId: conversationId, userId: userId, seq: Int(seq))
            }
        case "user":
            if let user = event.payload["user"]?.decode(User.self) {
                users[user.id] = user
                if user.id == me?.id { me = user }
            }
        case "settings":
            if let scope = event.payload["scope"]?.stringValue, let key = event.payload["key"]?.stringValue {
                let value = event.payload["value"] ?? .null
                if scope == "shared" { settings.shared[key] = value } else { settings.mine[key] = value }
            }
        case "stickers":
            // 发了一张贴纸：原地挪到前面；别的改动（加、删、分组）重新拉整份
            if let used = event.payload["used"], let id = used["id"]?.stringValue, let at = used["usedAt"]?.doubleValue {
                markStickerUsed(id, at: at)
            } else {
                Task { await reloadStickers() }
            }
        default:
            revision[event.kind, default: 0] += 1
            if event.kind == "album" { refreshAlbumUnread(after: 1) }
        }
        scheduleSave()
    }

    private func receive(_ message: Message, live: Bool) {
        let previous = conversations[message.conversationId]?.lastMessage
        let isNew = message.seq > (previous?.seq ?? 0)
        chats[message.conversationId]?.upsert(message)
        guard var summary = conversations[message.conversationId] else { return }
        if isNew || previous?.id == message.id { summary.lastMessage = message }
        let fromOther = message.senderId != me?.id
        if isNew && fromOther && focusedConversation != message.conversationId && message.recalledAt == nil {
            summary.unreadCount += 1
        }
        conversations[message.conversationId] = summary
        guard isNew, fromOther else { return }
        typing[message.conversationId] = nil
        if message.senderId == "daju" { dajuActivity[message.conversationId] = nil }
        guard live || (announceCatchUp && Date().timeIntervalSince(message.date) < 90) else { return }
        if focusedConversation == message.conversationId && appActive {
            if message.kind == "interaction", let interaction = message.payload.interaction {
                interactionEffect = InteractionEffectRequest(interaction: interaction, fromMe: false)
            }
        } else if appActive {
            showBanner(for: message)
        }
    }

    private func applyRead(conversationId: String, userId: String, seq: Int) {
        guard var summary = conversations[conversationId] else { return }
        if let index = summary.readStates.firstIndex(where: { $0.userId == userId }) {
            summary.readStates[index].seq = max(summary.readStates[index].seq, seq)
        } else {
            summary.readStates.append(ReadState(userId: userId, seq: seq))
        }
        if userId == me?.id, seq >= (summary.lastMessage?.seq ?? 0) { summary.unreadCount = 0 }
        conversations[conversationId] = summary
        chats[conversationId]?.readStatesChanged()
    }

    func readSeq(_ conversationId: String, userId: String) -> Int {
        conversations[conversationId]?.readStates.first { $0.userId == userId }?.seq ?? 0
    }

    /// 标记已读：本地立刻清零，接口失败也没关系，下次还会再标
    func markRead(_ conversationId: String, seq: Int) {
        guard var summary = conversations[conversationId], let me else { return }
        let current = readSeq(conversationId, userId: me.id)
        guard seq > current || summary.unreadCount > 0 else { return }
        summary.unreadCount = 0
        conversations[conversationId] = summary
        applyRead(conversationId: conversationId, userId: me.id, seq: seq)
        let api = self.api
        Task { try? await api.send("POST", "v1/conversations/\(conversationId)/read", body: ["seq": seq]) }
        updateBadge()
    }

    func reloadStickers() async {
        if let response: StickerState = try? await api.get("v1/stickers") { applyStickers(response) }
    }

    /// 贴纸接口都返回最新的贴纸和分组
    func applyStickers(_ state: StickerState) {
        stickers = state.stickers
        stickerGroups = state.groups ?? stickerGroups
        scheduleSave()
    }

    /// 刚发过的贴纸排到最前面（和服务端一样按“加的时间、最后发的时间”里晚的那个排）
    func markStickerUsed(_ id: String, at: Double = Date().timeIntervalSince1970 * 1000) {
        guard let index = stickers.firstIndex(where: { $0.id == id }) else { return }
        var updated = stickers
        updated[index].usedAt = max(updated[index].usedAt ?? 0, at)
        updated.sort { max($0.usedAt ?? 0, $0.createdAt) > max($1.usedAt ?? 0, $1.createdAt) }
        guard updated != stickers else { return }
        stickers = updated
        scheduleSave()
    }

    // MARK: - 横幅

    private func showBanner(for message: Message) {
        let title = message.senderId == "daju" ? (daju?.displayName ?? "大橘") : name(message.senderId)
        banner = Banner(conversationId: message.conversationId, senderId: message.senderId, title: title, body: MessagePreview.text(message, app: self))
        Haptics.soft()
        bannerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.banner = nil }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    // MARK: - 前后台

    func sceneBecameActive() {
        if !appActive { activeSince = Date() }
        appActive = true
        guard phase == .ready else { return }
        realtime.connect()
        realtime.reconnectNow()
    }

    func sceneEnteredBackground() {
        appActive = false
        guard phase == .ready else { return }
        realtime.disconnect()
        saveNow()
        updateBadge()
    }

    func updateBadge() {
        UNUserNotificationCenter.current().setBadgeCount(totalUnread) { _ in }
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "whisper" else { return }
        if url.host == "chat" {
            // whisper://chat/<会话>?m=<消息 id>：打开会话并定位到这条消息；不带 m 时回到最新
            let id = url.pathComponents.dropFirst().first ?? "couple"
            let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "m" }?.value
            openConversationRequest = id
            let model = chat(id)
            Task {
                if let target { await model.jump(to: target) } else { await model.jumpToLatest() }
            }
        } else if url.host == "tab", let tab = url.pathComponents.dropFirst().first {
            tabRequest = tab
        } else if url.host == "page", let page = url.pathComponents.dropFirst().first, let tab = Self.pageTabs[page] {
            tabRequest = tab
            pageRequest = page
        } else if url.host == "album", let id = url.pathComponents.dropFirst().first {
            tabRequest = "us"
            albumRequest = id
        } else if url.host == "home" {
            // 回到聊天首页（会话列表）
            openConversationRequest = ""
        }
    }

    /// 子页面属于哪个标签页
    static let pageTabs: [String: String] = [
        "anniversaries": "us", "plans": "us", "albums": "us", "stats": "us", "wishes": "us", "capsules": "us", "gallery": "us",
        "cards": "daju", "diary": "daju", "memories": "daju", "runs": "daju",
        "tags": "me", "partner": "me", "daju-profile": "me", "notifications": "me", "appearance": "me", "devices": "me", "storage": "me",
    ]

    /// 取走属于这个标签页的子页面请求
    func takePageRequest(for tab: String) -> String? {
        guard let page = pageRequest, Self.pageTabs[page] == tab else { return nil }
        pageRequest = nil
        return page
    }

    /// 自动化截图用：启动参数 -route，例如 tab/us、home、chat/couple?m=<消息 id>
    private func openLaunchRoute() {
        guard !launchRouteOpened, let route = UserDefaults.standard.string(forKey: "route"), let url = URL(string: "whisper://\(route)") else { return }
        launchRouteOpened = true
        handleDeepLink(url)
    }

    /// 自动化截图用：启动参数 -autologin 用户名:密码
    func autoLoginIfRequested() {
        guard phase == .loggedOut, let value = UserDefaults.standard.string(forKey: "autologin"), let colon = value.firstIndex(of: ":") else { return }
        let username = String(value[..<colon])
        let password = String(value[value.index(after: colon)...])
        Task { try? await login(username: username, password: password) }
    }

    // MARK: - 缓存

    private func restore(_ cache: CacheSnapshot) {
        me = cache.me
        users = Dictionary(uniqueKeysWithValues: cache.users.map { ($0.id, $0) })
        conversations = Dictionary(uniqueKeysWithValues: cache.conversations.map { ($0.id, $0) })
        settings = cache.settings
        stickers = cache.stickers
        stickerGroups = cache.stickerGroups ?? []
        features = cache.features
        lastSeq = cache.lastSeq
        for (conversationId, messages) in cache.recent where !messages.isEmpty {
            chat(conversationId).restore(messages)
        }
    }

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func saveNow() {
        guard let me, phase == .ready else { return }
        var recent: [String: [Message]] = [:]
        for (id, chat) in chats { recent[id] = chat.snapshotForCache() }
        let snapshot = CacheSnapshot(
            me: me,
            users: Array(users.values),
            conversations: Array(conversations.values),
            settings: settings,
            stickers: stickers,
            stickerGroups: stickerGroups,
            features: features,
            lastSeq: lastSeq,
            recent: recent
        )
        LocalCache.save(snapshot, as: "snapshot")
    }

    // MARK: - 设置

    func setSetting(_ key: String, _ value: JSONValue, shared: Bool) async {
        if shared { settings.shared[key] = value } else { settings.mine[key] = value }
        let encoded = try? JSONEncoder().encode(value)
        let object = encoded.flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) } ?? NSNull()
        _ = try? await api.send("PUT", "v1/settings", body: ["scope": shared ? "shared" : "me", "key": key, "value": object])
    }

    func sendTyping(_ conversationId: String) {
        realtime.sendTyping(conversationId)
    }

    func playInteraction(_ interaction: String) {
        interactionEffect = InteractionEffectRequest(interaction: interaction, fromMe: true)
    }
}

/// 消息的一句话摘要：会话列表、横幅、回复引用都用它
enum MessagePreview {
    static let interactionText: [String: String] = [
        "miss": "想你了", "pat": "拍了拍你", "poke": "戳了戳你", "flower": "送你一朵花", "heart": "给你比心",
        "hug": "抱抱你", "kiss": "亲亲你", "fireworks": "为你放了烟花", "poop": "丢给你一坨便便",
    ]

    static let interactionEmoji: [String: String] = [
        "miss": "💗", "pat": "👋", "poke": "👉", "flower": "🌹", "heart": "🫶", "hug": "🤗", "kiss": "😘",
        "fireworks": "🎆", "poop": "💩", "note": "🪧",
    ]

    @MainActor
    static func text(_ message: Message, app: AppModel?) -> String {
        if message.isRecalled { return "撤回了一条消息" }
        switch message.kind {
        case "text": return plain(message.text)
        case "image": return message.media.count > 1 ? "[\(message.media.count) 张图片]" : "[图片]"
        case "video": return "[视频]"
        case "voice": return "[语音] \(Format.voiceSeconds(message.media.first?.durationMs))"
        case "sticker": return "[贴纸]"
        case "file": return "[文件] \(message.media.first?.name ?? "")"
        case "interaction":
            let interaction = message.payload.interaction ?? ""
            if interaction == "note" { return "🪧 \(message.text)" }
            return "\(interactionEmoji[interaction] ?? "") \(interactionText[interaction] ?? "互动")"
        case "card": return "[卡牌] \(message.payload.title ?? "")"
        case "reminder": return "⏰ \(message.text)"
        case "confirm": return "[待确认] \(message.text.components(separatedBy: "\n").first ?? "")"
        case "system": return message.text
        default: return message.text.isEmpty ? "[消息]" : message.text
        }
    }

    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
