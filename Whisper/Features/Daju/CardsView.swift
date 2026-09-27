import SwiftUI
import UIKit

/// 情侣特权卡：每日翻牌、卡包、进行中、图鉴
struct CardsView: View {
    @Environment(AppModel.self) private var app
    /// 先用上次存下的；翻牌结果只有是今天存的才算数
    @State private var overview: CardOverview? = ResponseCache.shared.value(CardOverview.self, for: "v1/cards")
    @State private var tab = 0
    @State private var flips: [Int: FlipOutcome] = CardsView.cachedFlips()
    /// 今天翻了哪几张已经确定（今天的缓存或者网络回来了）；确定之前牌不能点，也不会先显示成六张都没翻
    @State private var boardReady = CardsView.cachedFlipsAreToday()
    @State private var drawing: DrawState?
    @State private var selected: Card?
    @State private var toast: Toast?

    private var total: Int { overview?.flipsPerDay ?? 6 }

    static func cachedFlipsAreToday() -> Bool {
        ResponseCache.shared.value(CardOverview.self, for: "v1/cards")?.day == Format.dayKey(Date())
    }

    static func cachedFlips() -> [Int: FlipOutcome] {
        guard let cached = ResponseCache.shared.value(CardOverview.self, for: "v1/cards"), cached.day == Format.dayKey(Date()) else { return [:] }
        return Dictionary((cached.todayFlips ?? []).map { ($0.slot, FlipOutcome(card: $0.card)) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 18) {
                    CardsHero(overview: overview)
                    FlipBoard(flips: flips, total: total, drawingSlot: drawing?.slot) { slot in
                        Task { await flip(slot) }
                    }
                    .disabled(!boardReady)
                    .opacity(boardReady ? 1 : 0.55)
                    .overlay {
                        if !boardReady {
                            ProgressView("看看今天翻了哪几张…")
                                .font(.footnote)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .glassEffect()
                        }
                    }
                    .animation(.easeOut(duration: 0.25), value: boardReady)
                    CardTabs(selection: $tab)
                    switch tab {
                    case 0: inventory
                    case 1: plays
                    default: collection
                    }
                }
                .padding(16)
            }
            .background(Paper.canvas)

            if let drawing {
                DrawStage(state: drawing, remaining: max(0, total - flips.count - 1), onBigWin: { app.playInteraction("fireworks") }) {
                    finishDraw()
                }
                .zIndex(2)
                .transition(.opacity)
            }
        }
        .paperList()
        .navigationTitle("特权卡")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(drawing == nil ? .automatic : .hidden, for: .navigationBar)
        .toast($toast)
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: app.revision["cards"]) { _, _ in Task { await load() } }
        .sheet(item: $selected) { card in
            CardDetailSheet(card: card, overview: overview) { message in
                toast = Toast(message: message, icon: "sparkles")
                Task { await load() }
            }
        }
    }

    private func load() async {
        guard let value: CardOverview = try? await app.api.get("v1/cards", cache: true) else { return }
        overview = value
        flips = Dictionary((value.todayFlips ?? []).map { ($0.slot, FlipOutcome(card: $0.card)) }, uniquingKeysWith: { first, _ in first })
        boardReady = true
    }

    /// 点牌后牌先飞到舞台上蓄力，请求回来再翻面，不用干等网络
    private func flip(_ slot: Int) async {
        guard drawing == nil, flips[slot] == nil else { return }
        Haptics.rigid()
        withAnimation(.easeOut(duration: 0.2)) { drawing = DrawState(slot: slot) }
        do {
            let result: CardDrawResult = try await app.api.post("v1/cards/draw", ["slot": slot])
            drawing?.outcome = FlipOutcome(card: result.card)
        } catch {
            withAnimation(.easeOut(duration: 0.2)) { drawing = nil }
            toast = Toast(message: error.localizedDescription, icon: "exclamationmark.circle")
            await load()
        }
    }

    private func finishDraw() {
        guard let drawing else { return }
        if let outcome = drawing.outcome { flips[drawing.slot] = outcome }
        withAnimation(.easeOut(duration: 0.25)) { self.drawing = nil }
        Task { await load() }
    }

    // MARK: 卡包

    @ViewBuilder
    private var inventory: some View {
        let cards = overview?.cards ?? []
        if cards.isEmpty {
            ContentUnavailableView("卡包是空的", systemImage: "rectangle.stack", description: Text("每天翻牌，翻中的都会留在这里"))
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(cards) { card in
                    Button { selected = card } label: { CardFace(card: CardFaceData(card), large: false) }
                        .buttonStyle(.plain)
                }
            }
        }
        if let partnerCards = overview?.partnerCards, !partnerCards.isEmpty {
            Text("\(app.partner.map { app.name($0.id) } ?? "TA") 有 \(partnerCards.count) 张卡")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 进行中

    @ViewBuilder
    private var plays: some View {
        let list = (overview?.plays ?? []).filter { $0.status == "pending" || $0.status == "accepted" }
        if list.isEmpty {
            ContentUnavailableView("没有进行中的卡", systemImage: "hourglass", description: Text("对 TA 用卡后会显示在这里"))
        }
        ForEach(list) { play in
            PlayRow(play: play) { accept in Task { await respond(play, accept) } }
        }
        let history = (overview?.plays ?? []).filter { $0.status == "done" || $0.status == "declined" }
        if !history.isEmpty {
            PaperSectionTitle(title: "出牌记录").padding(.top, 6)
            ForEach(history.prefix(15)) { play in PlayRow(play: play) { _ in } }
        }
    }

    private func respond(_ play: CardPlay, _ accept: Bool) async {
        do {
            _ = try await app.api.send("POST", "v1/cards/plays/\(play.id)/respond", body: ["accept": accept])
            Haptics.success()
            await load()
        } catch {
            toast = Toast(message: error.localizedDescription, icon: "exclamationmark.circle")
        }
    }

    // MARK: 图鉴

    @ViewBuilder
    private var collection: some View {
        let owned = Set((overview?.collection ?? []).map { "\($0.key)|\($0.rarity)" })
        let catalog = overview?.catalog ?? []
        Text("已收集 \(owned.count)/\(catalog.count)").font(.subheadline).foregroundStyle(Paper.inkSoft)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
            ForEach(catalog, id: \.self) { definition in
                let has = owned.contains("\(definition.key)|\(definition.rarity)")
                CardFace(card: CardFaceData(definition), large: false, compact: true)
                    .saturation(has ? 1 : 0)
                    .opacity(has ? 1 : 0.45)
            }
        }
    }
}

/// 特权卡的配色：牌背是陶土色，稀有度用 Theme.rarityColors（偏柔和的四种颜色）
enum CardPalette {
    static let terracotta = Color(hex: 0xB9614A)
    static let back = [Color(hex: 0xD98A6A), Color(hex: 0xB0553F)]
    static let cream = Color(hex: 0xFFF1DE)

    static func rarity(_ rarity: String) -> [Color] {
        (Theme.rarityColors[rarity] ?? Theme.rarityColors["common"]!).map { Color(hex: $0) }
    }
}

/// 顶部：标题、三张叠着的牌、保底说明、图鉴和卡包数量
private struct CardsHero: View {
    let overview: CardOverview?

    var body: some View {
        let owned = Set((overview?.collection ?? []).map { "\($0.key)|\($0.rarity)" }).count
        let catalog = overview?.catalog.count ?? 0
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("情侣特权卡").font(Paper.title(.title2)).foregroundStyle(Paper.ink)
                    Text("翻到就留下，想用时再出牌").font(.subheadline).foregroundStyle(Paper.inkSoft)
                }
                Spacer()
                ZStack {
                    ForEach(0 ..< 3, id: \.self) { index in
                        CardBackFace()
                            .frame(width: 34, height: 48)
                            .rotationEffect(.degrees(Double(index - 1) * 12))
                            .offset(x: CGFloat(index - 1) * 13, y: index == 1 ? -3 : 0)
                    }
                }
                .frame(width: 84, height: 60)
            }
            Text(pityText)
                .font(.footnote)
                .foregroundStyle(Paper.ink.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Paper.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack {
                Label("图鉴 \(owned)/\(catalog)", systemImage: "book.closed.fill")
                Spacer()
                Label("卡包 \(overview?.cards.count ?? 0) 张", systemImage: "rectangle.stack.fill")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(CardPalette.terracotta)
        }
        .paperCard(padding: 18, radius: 26)
    }

    private var pityText: String {
        var text = "每天六张背面朝上的牌，每张大约六分之一翻中，前五张都没中第六张必中。"
        if let pity = overview?.pity {
            text += "再翻中 \(max(1, pity.guaranteeAt - pity.sinceLegendary)) 张必出传说。"
        }
        return text
    }
}

/// 我的卡包 / 进行中 / 图鉴：纸色的分段按钮
private struct CardTabs: View {
    @Binding var selection: Int
    @Namespace private var namespace
    private let titles = ["我的卡包", "进行中", "图鉴"]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(titles.indices, id: \.self) { index in
                Button {
                    Haptics.selection()
                    withAnimation(.snappy(duration: 0.25)) { selection = index }
                } label: {
                    Text(titles[index])
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selection == index ? Color.white : Paper.inkSoft)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            if selection == index {
                                Capsule().fill(CardPalette.terracotta).matchedGeometryEffect(id: "tab", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Paper.inset, in: Capsule())
        .overlay(Capsule().strokeBorder(Paper.line.opacity(0.8), lineWidth: 0.6))
    }
}

/// 翻过的一张牌：card 为空表示没翻中
struct FlipOutcome: Equatable {
    let card: Card?
}

/// 正在抽的那张：outcome 为空表示请求还没回来
struct DrawState: Equatable {
    let slot: Int
    var outcome: FlipOutcome?
}

/// 今天的六张牌。都是静态的，没有常驻动画，滚动和点击不卡
private struct FlipBoard: View {
    let flips: [Int: FlipOutcome]
    let total: Int
    let drawingSlot: Int?
    let onFlip: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("今日翻牌").font(Paper.title(.headline)).foregroundStyle(Paper.ink)
                    Text(flips.count >= total ? "今天的牌翻完了，明天 0 点换新牌" : "挑一张翻开，每天 0 点换新牌")
                        .font(.caption)
                        .foregroundStyle(Paper.inkSoft)
                }
                Spacer()
                Text("\(flips.count) / \(total)")
                    .font(.system(.title2, design: .serif).weight(.bold).monospacedDigit())
                    .foregroundStyle(flips.count < total ? CardPalette.terracotta : Paper.inkSoft)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
                ForEach(0 ..< total, id: \.self) { slot in
                    FlipSlot(slot: slot, outcome: flips[slot], lifted: drawingSlot == slot) { onFlip(slot) }
                        .disabled(flips[slot] != nil || drawingSlot != nil)
                }
            }
        }
        .cardStyle()
    }
}

/// 桌上的一张牌：没翻的背面朝上微微歪着；翻过的显示结果；正在抽的那张飞到了舞台上，这里只留个空位
private struct FlipSlot: View {
    let slot: Int
    let outcome: FlipOutcome?
    let lifted: Bool
    let onTap: () -> Void

    private var tilt: Double { [-2.4, 1.6, -1.2, 2.2, -1.8, 1.4][slot % 6] }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if lifted {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(CardPalette.terracotta.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                } else if let outcome {
                    if let card = outcome.card { SlotCardFace(card: card) } else { MissFace() }
                } else {
                    CardBackFace()
                        .rotationEffect(.degrees(tilt))
                }
            }
            .aspectRatio(0.68, contentMode: .fit)
        }
        .buttonStyle(PressableCardStyle())
    }
}

/// 按下去缩一点，松手弹回
private struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.45), value: configuration.isPressed)
    }
}

/// 翻转到一半时换面：角度过了 90° 才显示正面
private struct FlipVisibility: ViewModifier, Animatable {
    var angle: Double
    let front: Bool

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity((angle >= 90) == front ? 1 : 0)
    }
}

/// 牌背：陶土色，一圈奶油色细框，中间一枚爱心火漆印，底下细细的点纹
private struct CardBackFace: View {
    var big = false

    var body: some View {
        let radius: CGFloat = big ? 24 : 12
        ZStack {
            LinearGradient(colors: CardPalette.back, startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                let step: CGFloat = big ? 16 : 9
                var y: CGFloat = step / 2
                var row = 0
                while y < size.height {
                    var x: CGFloat = row.isMultiple(of: 2) ? step / 2 : step
                    while x < size.width {
                        let dot = CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)
                        context.fill(Path(ellipseIn: dot), with: .color(CardPalette.cream.opacity(0.18)))
                        x += step
                    }
                    y += step
                    row += 1
                }
            }
            RoundedRectangle(cornerRadius: radius - (big ? 8 : 4), style: .continuous)
                .strokeBorder(CardPalette.cream.opacity(0.7), lineWidth: big ? 1.6 : 0.8)
                .padding(big ? 10 : 4)
            Circle()
                .fill(CardPalette.cream)
                .frame(width: big ? 76 : 18, height: big ? 76 : 18)
                .overlay(Image(systemName: "heart.fill").font(.system(size: big ? 32 : 8)).foregroundStyle(CardPalette.terracotta))
                .shadow(color: .black.opacity(0.15), radius: big ? 4 : 1, y: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: Color(hex: 0x7A3B28).opacity(big ? 0.3 : 0.18), radius: big ? 18 : 4, y: big ? 8 : 2)
    }
}

/// 桌上翻中的牌：上面是稀有度颜色和图标，下面纸色写名字
private struct SlotCardFace: View {
    let card: Card

    var body: some View {
        let colors = CardPalette.rarity(card.rarity)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: card.icon).font(.title3.weight(.semibold)).foregroundStyle(.white)
            }
            .frame(maxHeight: .infinity)
            Text(card.title)
                .font(.system(.caption2, design: .serif).weight(.bold))
                .foregroundStyle(Paper.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Paper.card)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(colors.last!.opacity(0.85), lineWidth: card.rarity == "legendary" ? 2 : 1.2))
    }
}

private struct MissFace: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 6) {
            Image(systemName: "heart").font(.system(size: 22, weight: .semibold)).foregroundStyle(Color(hex: 0xE59A9A))
            Text("差一点").font(.system(.caption, design: .serif).weight(.semibold)).foregroundStyle(Paper.inkSoft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Paper.inset, in: shape)
        .overlay(shape.strokeBorder(Color(hex: 0xE59A9A).opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
    }
}

// MARK: - 抽卡舞台

/// 抽卡舞台：牌飞到中间蓄力 → 结果回来后翻面 → 翻中了按稀有度放光、喷粒子、扫光；稀有度越高越热闹
private struct DrawStage: View {
    let state: DrawState
    let remaining: Int
    let onBigWin: () -> Void
    let onClose: () -> Void

    @State private var appeared = false
    @State private var floating = false
    @State private var pulsing = false
    @State private var angle: Double = 0
    @State private var revealed = false
    @State private var burst = false
    @State private var flash: Double = 0
    @State private var showInfo = false
    @State private var shine: CGFloat = -1.3
    @State private var chargeStart = Date()

    private var card: Card? { state.outcome?.card }
    private var level: Int { ["common": 1, "rare": 2, "epic": 3, "legendary": 4][card?.rarity ?? ""] ?? 1 }
    private var colors: [UIColor] { (Theme.rarityColors[card?.rarity ?? "common"] ?? Theme.rarityColors["common"]!).map { UIColor(hex: $0) } }

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.62, 270)
            let height = width / 0.68
            ZStack {
                Color(hex: 0x1E1712).opacity(appeared ? 0.88 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { if showInfo { onClose() } }
                VStack(spacing: 26) {
                    Spacer(minLength: 0)
                    ZStack {
                        if revealed, card != nil {
                            LightRays(color: Color(uiColor: colors[0]), count: 6 + level * 3, radius: width * 1.5)
                                .frame(width: width * 3, height: width * 3)
                                .opacity(burst ? 0.4 + Double(level) * 0.15 : 0)
                                .scaleEffect(burst ? 1 : 0.2)
                                .allowsHitTesting(false)
                        }
                        if !revealed {
                            Circle()
                                .fill(RadialGradient(colors: [Color(hex: 0xF0B27A).opacity(0.7), Color(hex: 0xF0B27A).opacity(0)], center: .center, startRadius: 10, endRadius: width))
                                .frame(width: width * 2, height: width * 2)
                                .scaleEffect(pulsing ? 1.12 : 0.82)
                                .opacity(appeared ? 1 : 0)
                                .allowsHitTesting(false)
                        }
                        ZStack {
                            CardBackFace(big: true)
                                .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                                .modifier(FlipVisibility(angle: angle, front: false))
                            front
                                .rotation3DEffect(.degrees(angle - 180), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                                .modifier(FlipVisibility(angle: angle, front: true))
                        }
                        .frame(width: width, height: height)
                        .shadow(color: Color(uiColor: colors[0]).opacity(burst ? 0.9 : 0), radius: burst ? 28 : 0)
                        .offset(y: floating ? -8 : 8)
                        .scaleEffect(appeared ? (burst && level >= 3 ? 1.04 : 1) : 0.35)
                        ParticleBurst(colors: colors + [.white], level: level, fire: burst && card != nil)
                            .frame(width: geometry.size.width * 1.6, height: geometry.size.height * 1.2)
                            .allowsHitTesting(false)
                    }
                    .frame(width: width, height: height)
                    info
                        .frame(height: 150)
                        .opacity(showInfo ? 1 : 0)
                        .offset(y: showInfo ? 0 : 24)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                Color.white
                    .opacity(flash)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            chargeStart = Date()
            withAnimation(.spring(duration: 0.45, bounce: 0.3)) { appeared = true }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { floating = true }
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { pulsing = true }
            if state.outcome != nil { reveal() }
        }
        .onChange(of: state.outcome) { _, outcome in
            if outcome != nil { reveal() }
        }
    }

    @ViewBuilder
    private var front: some View {
        if let card {
            StageCardFront(card: card, shine: shine)
        } else {
            StageMissFace()
        }
    }

    @ViewBuilder
    private var info: some View {
        VStack(spacing: 10) {
            if let card {
                Text(["", "翻中了", "稀有！", "史诗！", "传说降临！"][level])
                    .font(.system(size: level >= 3 ? 36 : 30, weight: .heavy, design: .serif))
                    .foregroundStyle(LinearGradient(colors: CardPalette.rarity(card.rarity).map { $0.mix(with: .white, by: 0.25) }, startPoint: .leading, endPoint: .trailing))
                    .shadow(color: .black.opacity(0.35), radius: 6)
                    .scaleEffect(showInfo ? 1 : 0.6)
                Text("「\(card.title)」已经收进卡包，想用的时候再出牌")
                    .font(.subheadline)
                    .foregroundStyle(CardPalette.cream.opacity(0.85))
                    .multilineTextAlignment(.center)
                Button("收进卡包", action: onClose)
                    .buttonStyle(.glassProminent)
                    .tint(CardPalette.terracotta)
                    .controlSize(.large)
            } else if state.outcome != nil {
                Text("差一点～")
                    .font(.system(size: 30, weight: .heavy, design: .serif))
                    .foregroundStyle(CardPalette.cream)
                Text(remaining > 0 ? "这张是空的，今天还能翻 \(remaining) 张" : "今天的牌翻完了，明天再来")
                    .font(.subheadline)
                    .foregroundStyle(CardPalette.cream.opacity(0.8))
                Button(remaining > 0 ? "再挑一张" : "好吧", action: onClose)
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
    }

    /// 至少蓄力一会儿再翻，稀有度高的多憋一下；翻到一半时放光效
    private func reveal() {
        guard !revealed else { return }
        Task { @MainActor in
            let waited = Date().timeIntervalSince(chargeStart)
            if waited < 0.9 { try? await Task.sleep(for: .seconds(0.9 - waited)) }
            if card != nil, level >= 3 {
                Haptics.rigid()
                try? await Task.sleep(for: .milliseconds(260))
                Haptics.rigid()
                try? await Task.sleep(for: .milliseconds(200))
            }
            revealed = true
            withAnimation(.easeOut(duration: 0.2)) { floating = false }
            withAnimation(.spring(duration: 0.7, bounce: 0.28)) { angle = 180 }
            try? await Task.sleep(for: .milliseconds(300))
            if card != nil {
                withAnimation(.easeOut(duration: 0.5)) { burst = true }
                withAnimation(.easeOut(duration: 0.08)) { flash = level >= 3 ? 0.85 : (level == 2 ? 0.45 : 0.25) }
                Haptics.success()
                if level >= 3 { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
                if level >= 4 { onBigWin() }
                try? await Task.sleep(for: .milliseconds(90))
                withAnimation(.easeOut(duration: 0.6)) { flash = 0 }
            } else {
                Haptics.soft()
            }
            try? await Task.sleep(for: .milliseconds(260))
            withAnimation(.spring(duration: 0.5, bounce: 0.35)) { showInfo = true }
            if card != nil {
                withAnimation(.easeInOut(duration: level >= 3 ? 1.1 : 0.9)) { shine = 1.3 }
            }
        }
    }
}

/// 舞台上的大卡正面：和卡包里一样的纸牌，多一道扫光
private struct StageCardFront: View {
    let card: Card
    let shine: CGFloat

    var body: some View {
        CardFace(card: CardFaceData(card), large: true, fill: true)
            .overlay(ShineBand(offset: shine).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous)))
    }
}

private struct StageMissFace: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(spacing: 12) {
            Image(systemName: "heart.slash").font(.system(size: 46, weight: .semibold)).foregroundStyle(Color(hex: 0xE59A9A))
            Text("这张是空的").font(.system(.headline, design: .serif)).foregroundStyle(Paper.inkSoft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Paper.card, in: shape)
        .overlay(shape.strokeBorder(Color(hex: 0xE59A9A).opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
    }
}

/// 斜着扫过卡面的一道光，offset 从 -1.3 到 1.3（按卡宽算）
private struct ShineBand: View {
    let offset: CGFloat

    var body: some View {
        GeometryReader { geometry in
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.6), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: geometry.size.width * 0.45, height: geometry.size.height * 1.6)
                .rotationEffect(.degrees(18))
                .offset(x: offset * geometry.size.width, y: -geometry.size.height * 0.3)
        }
        .allowsHitTesting(false)
    }
}

/// 转动的放射光：一圈明暗相间的锥形渐变，先画成一张图再转，开销很小
private struct LightRays: View {
    let color: Color
    let count: Int
    let radius: CGFloat
    @State private var spin = false

    var body: some View {
        let stops = (0 ..< count * 2).map { index in
            Gradient.Stop(color: index.isMultiple(of: 2) ? color : color.opacity(0), location: Double(index) / Double(count * 2))
        } + [Gradient.Stop(color: color, location: 1)]
        Circle()
            .fill(AngularGradient(gradient: Gradient(stops: stops), center: .center))
            .mask(RadialGradient(colors: [.white, .white.opacity(0.5), .white.opacity(0)], center: .center, startRadius: 0, endRadius: radius))
            .drawingGroup()
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 16).repeatForever(autoreverses: false)) { spin = true }
            }
    }
}

/// 翻中时的粒子：从牌的中心炸开一次；史诗和传说再从上面撒一阵彩纸
private struct ParticleBurst: UIViewRepresentable {
    let colors: [UIColor]
    let level: Int
    let fire: Bool

    func makeUIView(context: Context) -> ParticleView { ParticleView() }

    func updateUIView(_ view: ParticleView, context: Context) {
        if fire { view.fire(colors: colors, level: level) }
    }
}

final class ParticleView: UIView {
    private let burst = CAEmitterLayer()
    private let confetti = CAEmitterLayer()
    private var fired = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        burst.birthRate = 0
        confetti.birthRate = 0
        layer.addSublayer(burst)
        layer.addSublayer(confetti)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        burst.frame = bounds
        burst.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        burst.emitterSize = CGSize(width: 80, height: 80)
        confetti.frame = bounds
        confetti.emitterPosition = CGPoint(x: bounds.midX, y: 0)
        confetti.emitterSize = CGSize(width: bounds.width, height: 1)
    }

    func fire(colors: [UIColor], level: Int) {
        guard !fired else { return }
        fired = true
        let strength = Float(level)
        burst.emitterShape = .circle
        burst.emitterMode = .outline
        burst.renderMode = .additive
        burst.emitterCells = colors.flatMap { color in
            [
                Self.spark(color: color, image: Self.dot, birthRate: 90 * strength, velocity: 200 + 45 * CGFloat(level)),
                Self.spark(color: color, image: Self.sparkle, birthRate: 30 * strength, velocity: 160 + 45 * CGFloat(level)),
            ]
        }
        burst.beginTime = CACurrentMediaTime()
        burst.birthRate = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.burst.birthRate = 0 }

        guard level >= 3 else { return }
        confetti.emitterShape = .line
        confetti.emitterCells = colors.map { Self.confettiPiece(color: $0, level: level) }
        confetti.beginTime = CACurrentMediaTime()
        confetti.birthRate = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + (level >= 4 ? 1.8 : 0.9)) { [weak self] in self?.confetti.birthRate = 0 }
    }

    private static func spark(color: UIColor, image: CGImage?, birthRate: Float, velocity: CGFloat) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = image
        cell.color = color.cgColor
        cell.birthRate = birthRate
        cell.lifetime = 1.5
        cell.lifetimeRange = 0.5
        cell.velocity = velocity
        cell.velocityRange = velocity * 0.6
        cell.emissionRange = .pi * 2
        cell.yAcceleration = 150
        cell.scale = 0.55
        cell.scaleRange = 0.35
        cell.scaleSpeed = -0.28
        cell.alphaSpeed = -0.65
        cell.spinRange = 5
        return cell
    }

    private static func confettiPiece(color: UIColor, level: Int) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = piece
        cell.color = color.cgColor
        cell.birthRate = level >= 4 ? 16 : 8
        cell.lifetime = 5
        cell.velocity = 150
        cell.velocityRange = 70
        cell.emissionLongitude = .pi / 2
        cell.emissionRange = .pi / 5
        cell.yAcceleration = 110
        cell.spin = 3
        cell.spinRange = 6
        cell.scale = 0.75
        cell.scaleRange = 0.3
        return cell
    }

    private static let dot: CGImage? = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
        UIColor.white.setFill()
        context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 10, height: 10))
    }.cgImage

    private static let sparkle: CGImage? = {
        let size = CGSize(width: 22, height: 22)
        guard let symbol = UIImage(systemName: "sparkle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .bold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal) else { return nil }
        return UIGraphicsImageRenderer(size: size).image { _ in symbol.draw(in: CGRect(origin: .zero, size: size)) }.cgImage
    }()

    private static let piece: CGImage? = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 14)).image { context in
        UIColor.white.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 14))
    }.cgImage
}

/// 卡面用到的字段（卡包里的卡和卡池定义都能显示）
struct CardFaceData {
    let title: String
    let summary: String
    let icon: String
    let rarity: String
    let durationMs: Int?

    init(_ card: Card) {
        title = card.title
        summary = card.summary
        icon = card.icon
        rarity = card.rarity
        durationMs = card.durationMs
    }

    init(_ definition: CardDefinition) {
        title = definition.title
        summary = definition.summary
        icon = definition.icon
        rarity = definition.rarity
        durationMs = definition.durationMs
    }
}

/// 纸牌：纸色底，上面一块稀有度颜色的“画”，衬线体的名字，右下角盖个稀有度的章
struct CardFace: View {
    let card: CardFaceData
    var large = false
    var compact = false
    /// 撑满给定的大小（抽卡舞台用）
    var fill = false

    var body: some View {
        let colors = CardPalette.rarity(card.rarity)
        let radius: CGFloat = compact ? 14 : (large ? 24 : 20)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "sparkle")
                    .font(.system(size: compact ? 30 : (large ? 90 : 56)))
                    .foregroundStyle(.white.opacity(0.13))
                    .offset(x: compact ? 22 : (large ? 70 : 42), y: compact ? -10 : -24)
                Image(systemName: card.icon)
                    .font(.system(size: compact ? 24 : (large ? 52 : 32), weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 56 : (large ? 150 : 86))
            .clipShape(RoundedRectangle(cornerRadius: radius - 6, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.system(compact ? .footnote : (large ? .title2 : .headline), design: .serif).weight(.bold))
                    .foregroundStyle(Paper.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if !compact {
                    Text(card.summary)
                        .font(large ? .subheadline : .caption)
                        .foregroundStyle(Paper.inkSoft)
                        .lineLimit(large ? 4 : 2)
                }
            }
            .padding(.horizontal, 3)
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                if !compact, let duration = card.durationMs {
                    Label("\(duration / 60000) 分钟", systemImage: "timer").font(.caption2).foregroundStyle(Paper.inkSoft)
                }
                Spacer(minLength: 0)
                RarityStamp(rarity: card.rarity, small: compact)
            }
            .padding(.horizontal, 3)
        }
        .padding(compact ? 7 : 9)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .frame(minHeight: fill ? nil : (compact ? 132 : (large ? 330 : 214)))
        .background(Paper.card, in: shape)
        .overlay(shape.strokeBorder((colors.last ?? .gray).opacity(0.9), lineWidth: card.rarity == "legendary" ? 2.2 : 1.4))
        .overlay(
            RoundedRectangle(cornerRadius: radius - 4, style: .continuous)
                .strokeBorder((colors.first ?? .gray).opacity(0.35), lineWidth: 0.8)
                .padding(4)
        )
        .shadow(color: Paper.shadow, radius: 8, y: 4)
    }
}

/// 稀有度的章：描边、衬线字、稍微歪一点
private struct RarityStamp: View {
    let rarity: String
    var small = false

    var body: some View {
        let color = CardPalette.rarity(rarity).last ?? .gray
        Text(Theme.rarityNames[rarity] ?? "")
            .font(.system(size: small ? 9 : 11, weight: .bold, design: .serif))
            .foregroundStyle(color)
            .padding(.horizontal, small ? 5 : 7)
            .padding(.vertical, small ? 1.5 : 2.5)
            .overlay(Capsule().strokeBorder(color.opacity(0.8), lineWidth: 1))
            .rotationEffect(.degrees(-5))
    }
}

private struct PlayRow: View {
    @Environment(AppModel.self) private var app
    let play: CardPlay
    let onRespond: (Bool) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 12) {
                Image(systemName: play.icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(LinearGradient(colors: CardPalette.rarity(play.rarity), startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(play.title).font(.system(.headline, design: .serif)).foregroundStyle(Paper.ink)
                    Text(description(now: context.date)).font(.caption).foregroundStyle(Paper.inkSoft)
                }
                Spacer()
                if play.status == "pending" && play.toUser == app.me?.id {
                    Button("拒绝") { onRespond(false) }.buttonStyle(.glass)
                    Button("接受") { onRespond(true) }.buttonStyle(.glassProminent).tint(CardPalette.terracotta)
                }
            }
            .paperCard(padding: 12)
        }
    }

    private func description(now: Date) -> String {
        let from = play.fromUser == app.me?.id ? "我" : app.name(play.fromUser)
        let to = play.toUser == app.me?.id ? "我" : app.name(play.toUser)
        switch play.status {
        case "pending": return "\(from) 对 \(to) 使用 · 等待接受"
        case "accepted":
            if let ends = play.endsAt {
                let remaining = Format.date(ends).timeIntervalSince(now)
                return remaining > 0 ? "\(from) → \(to) · 还剩 \(Format.countdown(remaining))" : "\(from) → \(to) · 已结束"
            }
            return "\(from) → \(to) · 进行中"
        case "declined": return "\(to) 拒绝了"
        default: return "\(from) → \(to) · 已完成"
        }
    }
}

/// 点开一张卡：使用、送给 TA；辅助卡要先选目标
private struct CardDetailSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let card: Card
    let overview: CardOverview?
    let onDone: (String) -> Void
    @State private var note = ""
    @State private var targetPlay: String?
    @State private var targetCard: String?
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            PaperForm {
                Section {
                    CardFace(card: CardFaceData(card), large: true)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                switch card.effect {
                case "addTime":
                    Section("给哪张正在计时的卡加时") {
                        let running = (overview?.plays ?? []).filter { $0.fromUser == app.me?.id && $0.status == "accepted" && ($0.endsAt ?? 0) > Date().timeIntervalSince1970 * 1000 }
                        if running.isEmpty { Text("你现在没有正在计时的卡").foregroundStyle(.secondary) }
                        Picker("目标", selection: $targetPlay) {
                            Text("选择").tag(String?.none)
                            ForEach(running) { play in Text(play.title).tag(String?.some(play.id)) }
                        }
                    }
                case "copy":
                    Section("复制 TA 的哪张卡") {
                        Picker("目标", selection: $targetCard) {
                            Text("选择").tag(String?.none)
                            ForEach(overview?.partnerCards ?? []) { item in
                                Text("\(Theme.rarityNames[item.rarity] ?? "")·\(item.title)").tag(String?.some(item.id))
                            }
                        }
                    }
                case "bounce":
                    Section("反弹哪张卡") {
                        let incoming = (overview?.plays ?? []).filter { $0.toUser == app.me?.id && $0.status == "pending" }
                        if incoming.isEmpty { Text("TA 现在没有对你用卡").foregroundStyle(.secondary) }
                        Picker("目标", selection: $targetPlay) {
                            Text("选择").tag(String?.none)
                            ForEach(incoming) { play in Text(play.title).tag(String?.some(play.id)) }
                        }
                    }
                default:
                    Section("附一句话（可选）") {
                        TextField("比如：今晚就要！", text: $note)
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                Section {
                    Button {
                        Task { await play() }
                    } label: {
                        Label(card.effect == "timed" || card.effect == "instant" ? "对 TA 使用" : "使用", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(working)
                    Button {
                        Task { await gift() }
                    } label: {
                        Label("送给 TA", systemImage: "gift").frame(maxWidth: .infinity)
                    }
                    .disabled(working)
                }
            }
            .paperList()
            .navigationTitle(card.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }

    private func play() async {
        working = true
        defer { working = false }
        var body: [String: Any] = ["note": note]
        if let targetPlay { body["targetPlayId"] = targetPlay }
        if let targetCard { body["targetCardId"] = targetCard }
        do {
            _ = try await app.api.send("POST", "v1/cards/\(card.id)/play", body: body)
            Haptics.success()
            onDone("已经发到聊天里了")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func gift() async {
        working = true
        defer { working = false }
        do {
            _ = try await app.api.send("POST", "v1/cards/\(card.id)/gift")
            Haptics.success()
            onDone("送出去啦")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
