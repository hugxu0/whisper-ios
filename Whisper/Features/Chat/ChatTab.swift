import SwiftUI

/// 聊天标签页：首页 + 情侣聊天。默认启动时直接进入聊天（可以在“外观”里关掉）
struct ChatTab: View {
    @Environment(AppModel.self) private var app
    @State private var path: [String] = []
    @State private var didAutoOpen = false

    var body: some View {
        NavigationStack(path: $path) {
            HomeView { path = [$0] }
                .navigationDestination(for: String.self) { id in
                    ChatScreen(conversationId: id)
                }
        }
        .onAppear {
            guard !didAutoOpen else { return }
            didAutoOpen = true
            if let request = app.openConversationRequest {
                path = request.isEmpty ? [] : [request]
                app.openConversationRequest = nil
            } else if UserDefaults.standard.object(forKey: "openChatOnLaunch") as? Bool ?? true {
                path = ["couple"]
            }
        }
        .onChange(of: app.openConversationRequest) { _, id in
            guard let id else { return }
            path = id.isEmpty ? [] : [id]
            app.openConversationRequest = nil
        }
        // 退出聊天页：如果刚才在看搜索跳过去的历史，换回最新的一段，下次进来就是最新消息
        .onChange(of: path) { old, new in
            for id in old where !new.contains(id) { app.chat(id).leaveHistory() }
        }
    }
}

/// 聊天首页：两个人的状态、快捷互动、最新消息
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    let open: (String) -> Void
    @State private var showStatusPicker = false
    @State private var sentAction: String?
    @State private var upcoming: AnniversaryInfo?

    /// 首页的五个互动（和聊天里“互动”菜单一致）
    static let actions: [(key: String, emoji: String, title: String, color: UInt32)] = [
        ("miss", "💗", "想你了", 0xFBE0E6), ("hug", "🤗", "抱抱", 0xFBE9D3), ("kiss", "😘", "亲亲", 0xFADDE4),
        ("pat", "🖐️", "拍一拍", 0xF7E7D2), ("flower", "🌸", "送花", 0xF8E1EA),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                brandHeader
                mainCard
                if let upcoming { upcomingChip(upcoming) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(pageBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) { connectionNotice }
        .animation(.spring(duration: 0.35), value: app.connection == .connected)
        .refreshable {
            try? await app.bootstrap()
            await loadUpcoming()
        }
        .task {
            await loadUpcoming()
            await app.chat("couple").ensureLoaded()
        }
        .onChange(of: app.revision["anniversary"]) { _, _ in Task { await loadUpcoming() } }
        .sheet(isPresented: $showStatusPicker) { StatusPickerSheet() }
    }

    // MARK: 顶部

    private var brandHeader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "pawprint.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.orange.opacity(0.5))
                    .rotationEffect(.degrees(-14))
                Text("漫长悄悄话")
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .foregroundStyle(Paper.ink)
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(Color.pink.opacity(0.45))
            }
            Text("慢慢说，悄悄听")
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(Paper.inkSoft)
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity)
    }

    private var pageBackground: some View {
        LinearGradient(
            colors: [Theme.accentColor.opacity(colorScheme == .dark ? 0.08 : 0.06), .clear],
            startPoint: .top,
            endPoint: .center
        )
        .background(Paper.canvas)
    }

    @ViewBuilder
    private var connectionNotice: some View {
        if app.connection != .connected {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("正在连接…").font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .glassEffect()
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: 主卡片

    private var mainCard: some View {
        VStack(spacing: 0) {
            coupleHeader
                .padding(.top, 20)
                .padding(.bottom, 16)
            HomeDivider()
            actionStrip
                .padding(.vertical, 14)
            HomeDivider()
            latestWindow
                .padding(.top, 14)
            enterButton
                .padding(.vertical, 14)
        }
        .padding(.horizontal, 16)
        .background { HomeCardBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Paper.line.opacity(0.8), lineWidth: 0.6))
        .shadow(color: Paper.shadow, radius: 14, y: 5)
    }

    private var coupleHeader: some View {
        HStack(alignment: .center, spacing: 0) {
            CoupleAvatarColumn(
                userId: app.me?.id,
                name: app.me?.displayName ?? "我",
                status: app.me?.status,
                online: app.connection == .connected,
                editable: true
            ) { showStatusPicker = true }
            .frame(maxWidth: .infinity)
            bridge
                .frame(width: 96)
            CoupleAvatarColumn(
                userId: app.partner?.id,
                name: app.partner.map { app.name($0.id) } ?? "TA",
                status: app.partner?.status,
                online: app.partner.map { app.presence[$0.id]?.online == true } ?? false,
                editable: false
            ) {}
            .frame(maxWidth: .infinity)
        }
    }

    private var bridge: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                DashLine()
                Text("💗")
                    .font(.title3)
                    .fixedSize()
                    .layoutPriority(1)
                    .shadow(color: .pink.opacity(0.2), radius: 4, y: 1)
                DashLine()
            }
            Text(daysText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var daysText: String {
        guard let since = app.settings.shared["togetherSince"]?.stringValue, let date = Format.parseDay(since) else {
            return app.partner.map { app.presence[$0.id]?.online == true } == true ? "TA 在线" : Format.lastSeen(app.partner.flatMap { app.presence[$0.id]?.lastSeenAt })
        }
        return "在一起\n第 \(Format.daysBetween(date, Date()) + 1) 天"
    }

    // MARK: 快捷互动

    private var actionStrip: some View {
        HStack(spacing: 8) {
            ForEach(Self.actions, id: \.key) { action in
                Button { send(action.key) } label: {
                    VStack(spacing: 6) {
                        Text(sentAction == action.key ? "✓" : action.emoji)
                            .font(.system(size: 26))
                            .contentTransition(.opacity)
                        Text(action.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Paper.ink)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 76)
                    .background(Color(hex: action.color).opacity(colorScheme == .dark ? 0.14 : 0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(sentAction != nil)
            }
        }
    }

    private func send(_ key: String) {
        Haptics.success()
        app.chat("couple").sendInteraction(key)
        flashSent(key)
    }

    private func flashSent(_ key: String) {
        withAnimation(.spring(duration: 0.3)) { sentAction = key }
        Task {
            try? await Task.sleep(for: .seconds(1.3))
            withAnimation(.easeOut(duration: 0.25)) { if sentAction == key { sentAction = nil } }
        }
    }

    // MARK: 最新消息

    private var recentMessages: [Message] {
        let loaded = (app.chats["couple"]?.latestMessages ?? []).filter { !$0.isRecalled && $0.kind != "system" }
        if !loaded.isEmpty { return Array(loaded.suffix(3)) }
        return app.conversations["couple"]?.lastMessage.map { [$0] } ?? []
    }

    private var latestWindow: some View {
        let messages = recentMessages
        let unread = app.conversations["couple"]?.unreadCount ?? 0
        return Button { open("couple") } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("最新消息", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if unread > 0 {
                        Text("\(unread > 99 ? "99+" : String(unread)) 条未读")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.red, in: Capsule())
                    }
                    Spacer()
                    if let last = messages.last {
                        Text(Format.short(last.date))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                    }
                }
                if messages.isEmpty {
                    Text("还没有消息，进去说第一句吧")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 14)
                } else {
                    VStack(spacing: 7) {
                        ForEach(messages) { message in
                            LatestMessageRow(message: message)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .top)
            .background {
                ZStack(alignment: .bottomTrailing) {
                    Paper.inset
                    Image(systemName: "sparkles")
                        .font(.system(size: 52, weight: .thin))
                        .foregroundStyle(Theme.accentColor.opacity(0.10))
                        .rotationEffect(.degrees(-14))
                        .offset(x: 10, y: 12)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.accentColor.opacity(0.10))
                        .offset(x: -44, y: -14)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .buttonStyle(.plain)
    }

    private var enterButton: some View {
        Button {
            Haptics.tap()
            open("couple")
        } label: {
            HStack(spacing: 8) {
                Text("进入聊天").font(.headline)
                Image(systemName: "arrow.right").font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                LinearGradient(colors: Theme.palette.gradient.map { Color(uiColor: $0) }, startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .shadow(color: Theme.accentColor.opacity(0.25), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
    }

    // MARK: 纪念日

    private func loadUpcoming() async {
        struct List: Decodable { let anniversaries: [Anniversary] }
        // 先用上次存下的，不用等网络
        if upcoming == nil, let cached: List = app.api.cached("v1/anniversaries") { upcoming = Self.nearest(cached.anniversaries) }
        guard let list: List = try? await app.api.get("v1/anniversaries", cache: true) else { return }
        upcoming = Self.nearest(list.anniversaries)
    }

    private static func nearest(_ anniversaries: [Anniversary]) -> AnniversaryInfo? {
        anniversaries
            .map { AnniversaryInfo($0) }
            .filter { $0.isFuture || $0.days == 0 }
            .min { $0.days < $1.days }
    }

    private func upcomingChip(_ info: AnniversaryInfo) -> some View {
        HStack(spacing: 8) {
            AnniversaryIcon(info: info, size: 24)
            Text(info.anniversary.title).font(.subheadline.weight(.semibold)).foregroundStyle(Paper.ink)
            Text("·").foregroundStyle(Paper.inkSoft)
            Text(info.headline).font(.subheadline).foregroundStyle(Theme.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Paper.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Paper.line.opacity(0.8), lineWidth: 0.6))
        .shadow(color: Paper.shadow, radius: 8, y: 3)
    }
}

/// 首页卡片的底色和角落的小装饰
private struct HomeCardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            Paper.card
            LinearGradient(colors: [Theme.accentColor.opacity(colorScheme == .dark ? 0.08 : 0.05), .clear], startPoint: .topLeading, endPoint: .center)
            HStack {
                Image(systemName: "sparkles")
                Spacer()
                Image(systemName: "heart.fill").font(.caption2)
            }
            .font(.headline)
            .foregroundStyle(Theme.accentColor.opacity(0.18))
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
    }
}

private struct HomeDivider: View {
    var body: some View {
        LinearGradient(colors: [Paper.line.opacity(0.2), Paper.line, Paper.line.opacity(0.2)], startPoint: .leading, endPoint: .trailing)
            .frame(height: 0.8)
    }
}

/// 头像之间的虚线：被挤压时先缩虚线，爱心不动
private struct DashLine: View {
    var body: some View {
        DashShape()
            .stroke(Color.pink.opacity(0.28), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            .frame(minWidth: 10, idealWidth: 24, maxWidth: 36, maxHeight: 1.5)
    }

    private struct DashShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

/// 首页上的一个人：状态、头像（在线小绿点）、名字
private struct CoupleAvatarColumn: View {
    let userId: String?
    let name: String
    let status: String?
    let online: Bool
    let editable: Bool
    let onStatusTap: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            statusCapsule
            ZStack(alignment: .bottomTrailing) {
                AvatarView(userId: userId, size: 76)
                    .overlay(Circle().stroke(Color(uiColor: .systemBackground).opacity(0.9), lineWidth: 4))
                    .shadow(color: tint.opacity(0.22), radius: 10, y: 5)
                Circle()
                    .fill(online ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 15, height: 15)
                    .overlay(Circle().stroke(Paper.card, lineWidth: 3))
                    .offset(x: -3, y: -3)
            }
            .contentShape(Circle())
            .onTapGesture { if editable { onStatusTap() } }
            Text(name)
                .font(.headline)
                .lineLimit(1)
        }
    }

    private var hasStatus: Bool { !(status ?? "").isEmpty }
    private var tint: Color { hasStatus ? StatusColors.color(for: status ?? "") : Theme.accentColor }

    private var statusCapsule: some View {
        Button(action: onStatusTap) {
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(tint.opacity(0.18)).frame(width: 16, height: 16)
                    if !hasStatus && editable {
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                    } else {
                        Circle().fill(hasStatus ? tint : Color.secondary).frame(width: 7, height: 7)
                    }
                }
                Text(hasStatus ? (status ?? "") : (editable ? "加状态" : "暂无状态"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(hasStatus ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if editable {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(minWidth: 92, minHeight: 36)
            .background(Capsule().fill(tint.opacity(0.1)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!editable)
    }
}

/// 最新消息里的一行
private struct LatestMessageRow: View {
    @Environment(AppModel.self) private var app
    let message: Message

    var body: some View {
        let mine = message.senderId == app.me?.id
        HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 44) } else { AvatarView(userId: message.senderId, size: 28) }
            Text(MessagePreview.text(message, app: app))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(mine ? Theme.accentColor.opacity(0.16) : Paper.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if mine { AvatarView(userId: message.senderId, size: 28) } else { Spacer(minLength: 44) }
        }
    }
}

/// 状态的颜色：按文字固定，不随启动变化
enum StatusColors {
    static let palette: [Color] = [
        Color(red: 0.84, green: 0.30, blue: 0.50), Color(red: 0.38, green: 0.56, blue: 0.86),
        Color(red: 0.88, green: 0.56, blue: 0.24), Color(red: 0.55, green: 0.40, blue: 0.86),
        Color(red: 0.24, green: 0.68, blue: 0.56),
    ]

    static func color(for status: String) -> Color {
        palette[status.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count]
    }
}

/// 选我的状态：常用状态（可以自己加、左滑删除），会同步到两台手机
struct StatusPickerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var draft = ""

    static let defaults = ["在想你", "想贴贴", "忙完找你", "要亲亲"]

    private var presets: [String] {
        if case .array(let values) = app.settings.mine["statusPresets"] ?? .null {
            let list = values.compactMap(\.stringValue)
            if !list.isEmpty { return list }
        }
        return Self.defaults
    }

    var body: some View {
        NavigationStack {
            PaperList {
                Section("选择状态") {
                    ForEach(presets, id: \.self) { title in
                        Button {
                            Task { await set(title) }
                        } label: {
                            HStack(spacing: 11) {
                                Circle().fill(StatusColors.color(for: title)).frame(width: 10, height: 10)
                                Text(title).foregroundStyle(.primary)
                                Spacer()
                                if app.me?.status == title {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(StatusColors.color(for: title))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("删除", role: .destructive) { Task { await remove(title) } }
                        }
                    }
                }
                Section {
                    Button("添加自定义状态", systemImage: "plus.circle") {
                        draft = ""
                        adding = true
                    }
                    if !(app.me?.status ?? "").isEmpty {
                        Button("清除当前状态", systemImage: "xmark.circle", role: .destructive) {
                            Task { await set("") }
                        }
                    }
                }
            }
            .paperList()
            .navigationTitle("我的状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .alert("添加状态", isPresented: $adding) {
                TextField("比如：想被抱抱", text: $draft)
                Button("添加并使用") { Task { await add() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("最多 8 个字")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func set(_ status: String) async {
        Haptics.selection()
        struct Response: Decodable { let user: User }
        if let response: Response = try? await app.api.patch("v1/me", ["status": status]) {
            app.users[response.user.id] = response.user
            app.me = response.user
        }
        if !status.isEmpty { dismiss() }
    }

    private func add() async {
        let title = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8))
        guard !title.isEmpty else { return }
        var list = presets
        if !list.contains(title) { list.append(title) }
        await app.setSetting("statusPresets", .array(list.map { JSONValue.string($0) }), shared: false)
        await set(title)
    }

    private func remove(_ title: String) async {
        var list = presets.filter { $0 != title }
        if list.isEmpty { list = Self.defaults }
        await app.setSetting("statusPresets", .array(list.map { JSONValue.string($0) }), shared: false)
        if app.me?.status == title { await set("") }
    }
}
