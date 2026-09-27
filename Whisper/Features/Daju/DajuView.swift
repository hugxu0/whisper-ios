import SwiftUI

struct DajuView: View {
    @Environment(AppModel.self) private var app
    // 先用上次存下的内容，页面一打开就有；task 里再刷新
    @State private var pet: Pet? = ResponseCache.shared.value(PetResponse.self, for: "v1/pet")?.pet
    @State private var cards: CardOverview? = ResponseCache.shared.value(CardOverview.self, for: "v1/cards")
    @State private var diary: DajuDiary? = ResponseCache.shared.value(DiaryPage.self, for: ResponseCache.key("v1/daju/diaries", query: ["limit": "1"]))?.diaries.first
    @State private var reply: String?
    @State private var reaction = 0
    @State private var reactionKind = "stroke"
    @State private var busy = false
    @State private var toast: Toast?
    @State private var renaming = false
    @State private var newName = ""
    @State private var page: String?
    @State private var chatting = false

    private struct PetResponse: Decodable { let pet: Pet }
    private struct DiaryPage: Decodable { let diaries: [DajuDiary] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if let pet {
                        DajuStage(
                            pet: pet,
                            reply: reply,
                            reaction: reaction,
                            reactionKind: reactionKind,
                            busy: busy,
                            unread: app.dajuUnread,
                            onAction: { action in Task { await act(action) } },
                            onChat: { chatting = true }
                        )
                    } else {
                        ProgressView("正在叫醒大橘…").frame(maxWidth: .infinity, minHeight: 360)
                    }

                    VStack(spacing: 10) {
                        NavigationLink { DiaryView() } label: { PaperSectionTitle(title: "大橘日记", trailing: "全部") }
                            .buttonStyle(.plain)
                        NavigationLink {
                            if let diary { DiaryPageView(diary: diary) } else { DiaryView() }
                        } label: {
                            DiaryPreviewCard(diary: diary)
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(spacing: 10) {
                        NavigationLink { CardsView() } label: { PaperSectionTitle(title: "特权卡", trailing: "打开") }
                            .buttonStyle(.plain)
                        NavigationLink { CardsView() } label: { CardsPreviewCard(overview: cards) }
                            .buttonStyle(.plain)
                    }

                    if let pet, !pet.recent.isEmpty {
                        VStack(spacing: 10) {
                            PaperSectionTitle(title: "最近")
                            PetRecent(pet: pet)
                        }
                    }

                    PaperGroup(title: "更多") {
                        NavigationLink { MemoriesView() } label: {
                            PaperRow(icon: "brain.head.profile", tint: .purple, title: "大橘的记忆", subtitle: "它记得的关于你们的事")
                        }
                        NavigationLink { RunsView() } label: {
                            PaperRow(icon: "terminal.fill", tint: .gray, title: "运行记录", subtitle: "每次回答查了什么、做了什么")
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
                .padding(.bottom, 12)
            }
            .background(Paper.canvas.ignoresSafeArea())
            .navigationTitle(pet?.name ?? "大橘")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("给它改名字", systemImage: "pencil") {
                            newName = pet?.name ?? ""
                            renaming = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .toast($toast)
            .refreshable { await load() }
            .task { await load() }
            .onChange(of: app.revision["pet"]) { _, _ in Task { await loadPet() } }
            .onChange(of: app.revision["cards"]) { _, _ in Task { await loadCards() } }
            .onChange(of: app.revision["diary"]) { _, _ in Task { await loadDiary() } }
            .navigationDestination(item: $page) { destination($0) }
            .navigationDestination(isPresented: $chatting) { ChatScreen(conversationId: app.myDajuConversationId) }
            // 从私聊退出来：在看历史就换回最新的一段
            .onChange(of: chatting) { old, new in
                if old && !new { app.chat(app.myDajuConversationId).leaveHistory() }
            }
            .onAppear { if let next = app.takePageRequest(for: "daju") { page = next } }
            .onChange(of: app.pageRequest) { if let next = app.takePageRequest(for: "daju") { page = next } }
            .alert("给它起个名字", isPresented: $renaming) {
                TextField("名字", text: $newName)
                Button("取消", role: .cancel) {}
                Button("好") {
                    Task {
                        if let response: PetResponse = try? await app.api.patch("v1/pet", ["name": newName]) { pet = response.pet }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func destination(_ name: String) -> some View {
        switch name {
        case "cards": CardsView()
        case "diary": DiaryView()
        case "memories": MemoriesView()
        case "runs": RunsView()
        default: EmptyView()
        }
    }

    private func load() async {
        async let petTask: Void = loadPet()
        async let cardsTask: Void = loadCards()
        async let diaryTask: Void = loadDiary()
        _ = await (petTask, cardsTask, diaryTask)
    }

    private func loadPet() async {
        if let response: PetResponse = try? await app.api.get("v1/pet", cache: true) { pet = response.pet }
    }

    private func loadCards() async {
        if let value: CardOverview = try? await app.api.get("v1/cards", cache: true) { cards = value }
    }

    private func loadDiary() async {
        if let page: DiaryPage = try? await app.api.get("v1/daju/diaries", query: ["limit": "1"], cache: true) { diary = page.diaries.first }
    }

    private func act(_ action: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        reactionKind = action
        reaction += 1
        Haptics.soft()
        do {
            let response: PetActionResponse = try await app.api.post("v1/pet/actions", ["action": action])
            withAnimation(.spring(duration: 0.4)) {
                pet = response.pet
                reply = response.reply
            }
            if response.leveledUp {
                toast = Toast(message: "升级啦！现在 \(response.pet.level) 级", icon: "sparkles")
                Haptics.success()
            }
            let shown = response.reply
            Task {
                try? await Task.sleep(for: .seconds(3.5))
                if reply == shown { withAnimation { reply = nil } }
            }
        } catch {
            toast = Toast(message: error.localizedDescription, icon: "exclamationmark.circle")
            Haptics.warning()
        }
    }
}

/// 大橘的小舞台：天空（白天、夜晚）、3D 大橘、说的话、等级、状态、互动按钮、聊天入口
struct DajuStage: View {
    @Environment(\.colorScheme) private var colorScheme
    let pet: Pet
    let reply: String?
    let reaction: Int
    let reactionKind: String
    let busy: Bool
    /// 和大橘私聊里没看的消息
    var unread = 0
    let onAction: (String) -> Void
    let onChat: () -> Void

    private var night: Bool { colorScheme == .dark || pet.sleeping }

    var body: some View {
        VStack(spacing: 14) {
            modelStage
            growthRow
            needsGrid
            actionRow
            chatButton
        }
        .padding(16)
        .background(sky)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(night ? Color.white.opacity(0.12) : Paper.line, lineWidth: 0.8))
        .shadow(color: Paper.shadow, radius: 14, y: 6)
    }

    private var sky: some View {
        LinearGradient(
            colors: night
                ? [Color(red: 0.12, green: 0.13, blue: 0.28), Color(red: 0.08, green: 0.08, blue: 0.16)]
                : [Color(hex: 0xFFF4E3), Color(hex: 0xFBE3C8)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var modelStage: some View {
        ZStack(alignment: .top) {
            // 太阳或月亮
            Group {
                if night {
                    Circle().fill(.white.opacity(0.8)).frame(width: 44, height: 44)
                        .overlay(alignment: .topLeading) { Circle().fill(Color(red: 0.12, green: 0.13, blue: 0.28)).frame(width: 34, height: 34).offset(x: -8, y: -6) }
                        .padding(.top, 26)
                        .padding(.trailing, 22)
                } else {
                    Circle().fill(Color.yellow.opacity(0.32)).frame(width: 72, height: 72).blur(radius: 1)
                        .padding(.top, 22)
                        .padding(.trailing, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            Ellipse()
                .fill((night ? Color.black : Color.orange).opacity(0.12))
                .frame(width: 150, height: 24)
                .blur(radius: 7)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 14)

            CatModelView(reaction: reaction, reactionKind: reactionKind, sleeping: pet.sleeping) {
                onAction("stroke")
            }
            .frame(maxWidth: .infinity)
            .frame(height: 260)

            if pet.sleeping {
                Image(systemName: "zzz")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.8))
                    .symbolEffect(.variableColor.iterative, isActive: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 70)
                    .padding(.trailing, 70)
                    .allowsHitTesting(false)
            }

            Text(reply ?? pet.status)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(night ? Color.white.opacity(0.92) : Paper.ink)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .frame(maxWidth: 260)
                .padding(.top, 10)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: reply)
                .allowsHitTesting(false)
        }
        .frame(height: 280)
    }

    private var growthRow: some View {
        HStack(spacing: 10) {
            Text("Lv.\(pet.level)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(night ? 0.2 : 0.14), in: Capsule())
            Text(pet.stageLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(night ? Color.white.opacity(0.85) : Paper.inkSoft)
            MeterBar(value: Double(pet.xp) / Double(max(1, pet.xpToNext)), color: .orange, height: 7)
            Text("\(pet.xp)/\(pet.xpToNext)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(night ? Color.white.opacity(0.7) : Paper.inkSoft)
        }
        .padding(.horizontal, 4)
    }

    /// 四项状态排成两行两列，比一行一项紧凑
    private var needsGrid: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 11) {
            GridRow {
                need("饱食", "fork.knife", pet.satiety, .orange)
                need("清洁", "drop.fill", pet.cleanliness, .blue)
            }
            GridRow {
                need("心情", "heart.fill", pet.mood, .pink)
                need("精力", "bolt.fill", pet.energy, .green)
            }
        }
        .padding(14)
        .background((night ? Color.white.opacity(0.08) : Paper.card.opacity(0.75)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func need(_ title: String, _ icon: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption).foregroundStyle(color)
                Text(title).font(.caption.weight(.medium)).foregroundStyle(night ? Color.white.opacity(0.8) : Paper.inkSoft)
                Spacer(minLength: 0)
                Text("\(value)").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(night ? Color.white : Paper.ink)
            }
            MeterBar(value: Double(value) / 100, color: color, height: 6)
        }
    }

    private var actionRow: some View {
        let actions: [(key: String, icon: String, title: String)] = [
            ("feed", "fork.knife", "喂食"),
            ("treat", "fish.fill", "小鱼干"),
            ("bathe", "bathtub.fill", "洗澡"),
            ("play", "tennisball.fill", "玩耍"),
            ("stroke", "hand.wave.fill", "摸摸"),
            pet.sleeping ? ("wake", "sun.max.fill", "叫醒") : ("sleep", "moon.fill", "睡觉"),
        ]
        return HStack(spacing: 4) {
            ForEach(actions, id: \.key) { action in
                Button { onAction(action.key) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: action.icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.orange)
                            .frame(width: 42, height: 42)
                            .background(Color.orange.opacity(night ? 0.22 : 0.14), in: Circle())
                            .overlay(alignment: .topTrailing) {
                                if let limit = pet.limits[action.key] {
                                    Text("\(limit.max - limit.used)")
                                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .frame(minWidth: 16, minHeight: 16)
                                        .background(Color.orange, in: Capsule())
                                        .offset(x: 6, y: -4)
                                }
                            }
                        Text(action.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(night ? Color.white.opacity(0.88) : Paper.ink)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
    }

    private var chatButton: some View {
        Button(action: onChat) {
            HStack {
                Image(systemName: "bubble.left.fill")
                Text(unread > 0 ? "大橘回你了" : "和大橘聊一聊").font(.headline)
                Spacer()
                if unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(hex: 0xE8894A))
                        .padding(.horizontal, 8)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Color.white, in: Capsule())
                }
                Image(systemName: "chevron.right")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(hex: 0xE8894A).gradient, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 最近谁照顾了它
struct PetRecent: View {
    @Environment(AppModel.self) private var app
    let pet: Pet

    private let verbs = ["feed": "喂了它", "treat": "给了小鱼干", "bathe": "给它洗了澡", "play": "陪它玩了一会儿", "stroke": "摸了摸它", "sleep": "哄它睡觉", "wake": "把它叫醒了"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(pet.recent.prefix(5).enumerated()), id: \.offset) { _, record in
                HStack(spacing: 10) {
                    AvatarView(userId: record.userId, size: 24)
                    Text("\(record.userId == app.me?.id ? "我" : app.name(record.userId)) \(verbs[record.action] ?? record.action)")
                        .font(.subheadline)
                        .foregroundStyle(Paper.ink)
                    Spacer()
                    Text(Format.relative(record.at)).font(.caption).foregroundStyle(Paper.inkSoft)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }
}

/// 日记的预览：和日记本一样的纸，写着最近一篇的标题和开头
struct DiaryPreviewCard: View {
    let diary: DajuDiary?

    var body: some View {
        DiaryPaper {
            VStack(alignment: .leading, spacing: 8) {
                if let diary {
                    let text = DiaryText(diary.content)
                    Text(DiaryPalette.dayTitle(diary.day))
                        .font(.system(.footnote, design: .serif).weight(.semibold))
                        .foregroundStyle(DiaryPalette.ink.opacity(0.6))
                    if let title = text.title {
                        Text(title)
                            .font(.system(.title3, design: .serif).weight(.bold))
                            .foregroundStyle(DiaryPalette.ink)
                            .lineLimit(1)
                    }
                    Text(MessagePreview.plain(text.body.replacingOccurrences(of: "#", with: "")))
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(DiaryPalette.ink.opacity(0.75))
                        .lineLimit(2)
                        .lineSpacing(4)
                } else {
                    Text("大橘的日记本")
                        .font(.system(.title3, design: .serif).weight(.bold))
                        .foregroundStyle(DiaryPalette.ink)
                    Text("每天早上，它会把前一天你们的聊天写成一页手记")
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(DiaryPalette.ink.opacity(0.7))
                }
            }
            .padding(.vertical, 16)
            .padding(.leading, 8)
            .padding(.trailing, 18)
        }
        .overlay(alignment: .topTrailing) {
            WashiTape(color: DiaryPalette.tape(for: diary?.day ?? "daju"))
                .offset(x: -18, y: -8)
        }
    }
}

/// 特权卡的预览：今天的六张牌缩小排一排
struct CardsPreviewCard: View {
    let overview: CardOverview?

    /// 存下来的是不是今天的（昨天的翻牌结果不能拿来显示）
    private var isToday: Bool { overview?.day == Format.dayKey(Date()) }

    var body: some View {
        let total = overview?.flipsPerDay ?? 6
        let flips = Dictionary((isToday ? overview?.todayFlips ?? [] : []).map { ($0.slot, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(0 ..< total, id: \.self) { slot in
                    miniCard(flips[slot])
                }
            }
            .opacity(overview == nil || isToday ? 1 : 0.5)
            HStack {
                Text(headline).font(.subheadline.weight(.semibold)).foregroundStyle(Paper.ink)
                Spacer()
                Text(subtitle).font(.caption).foregroundStyle(Paper.inkSoft)
            }
        }
        .paperCard()
    }

    @ViewBuilder
    private func miniCard(_ flip: CardFlip?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Group {
            if let flip {
                if let card = flip.card {
                    shape.fill(Theme.rarityGradient(card.rarity))
                        .overlay(Image(systemName: card.icon).font(.caption).foregroundStyle(.white))
                } else {
                    shape.strokeBorder(Color.pink.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            } else {
                shape.fill(LinearGradient(colors: [Color(hex: 0x8B5CF6), Color(hex: 0x4D7CFF)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Image(systemName: "suit.heart.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.85)))
            }
        }
        .aspectRatio(0.7, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private var headline: String {
        guard let overview, isToday else { return "每天六张牌，翻中的都留进卡包" }
        let flipped = overview.todayFlips?.count ?? (overview.drawnToday ? 6 : 0)
        let total = overview.flipsPerDay ?? 6
        return flipped >= total ? "今天的牌翻完了" : "今天还能翻 \(total - flipped) 张"
    }

    private var subtitle: String {
        guard let overview else { return "" }
        let pending = overview.plays.filter { $0.status == "pending" }.count
        return "卡包 \(overview.cards.count) 张" + (pending > 0 ? " · \(pending) 张等接受" : "")
    }
}
