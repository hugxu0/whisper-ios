import PhotosUI
import SwiftUI
import UIKit

extension AnniversaryInfo {
    var isToday: Bool { days == 0 }
    var isCountdown: Bool { anniversary.kind == "countdown" }
    /// 还没到的（每年的、倒数日当天也算）：画圆环倒数。正数日从那天往后数，当天也不算倒数
    var countsDown: Bool {
        switch anniversary.kind {
        case "yearly": return true
        case "countdown": return isFuture || isToday
        default: return isFuture
        }
    }

    /// 圆环的进度：每年重复的按离上一次过了多少；倒数日和将来的日子按从开始数的那天（没设就是建它那天）到目标过了多少；过去的满格
    var progress: Double {
        if anniversary.kind == "yearly" {
            if days == 0 { return 1 }
            let previous = Format.calendar.date(byAdding: .year, value: -1, to: nextDate) ?? nextDate
            let cycle = max(1, Format.daysBetween(previous, nextDate))
            return max(0.02, 1 - Double(days) / Double(cycle))
        }
        guard isFuture else { return 1 }
        let total = max(1, Format.daysBetween(startDate, nextDate))
        return min(1, max(0.02, 1 - Double(days) / Double(total)))
    }

    /// 倒数从哪天开始算
    var startDate: Date {
        let start = anniversary.startDate.flatMap(Format.parseDay) ?? Format.date(anniversary.createdAt)
        return Format.calendar.startOfDay(for: start)
    }

    /// 已经等了几天（倒数用）
    var waitedDays: Int { max(0, Format.daysBetween(startDate, Format.calendar.startOfDay(for: Date()))) }

    var emoji: String { anniversary.emoji.isEmpty ? "📅" : anniversary.emoji }

    var tint: Color { AnniversaryStyle.color(anniversary.color) }

    /// 列表里的一行说明
    var subtitle: String {
        let original = Format.parseDay(anniversary.date).map { Format.fullDate.string(from: $0) } ?? anniversary.date
        if anniversary.kind == "yearly" {
            let next = Format.monthDayWeek.string(from: nextDate)
            if let years, years > 0 { return "\(next) · 第 \(years) 个" }
            return next
        }
        if isCountdown { return countsDown ? "\(original) · 倒数日" : "\(original) · 倒数结束了" }
        return isCountUp ? "\(original) · 正数日" : original
    }

    /// 先排还没到的（越近越前），再排已经过去的
    static func sorted(_ items: [Anniversary]) -> [AnniversaryInfo] {
        items.map { AnniversaryInfo($0) }.sorted { lhs, rhs in
            if lhs.countsDown != rhs.countsDown { return lhs.countsDown }
            if lhs.anniversary.pinned != rhs.anniversary.pinned { return lhs.anniversary.pinned }
            return lhs.days < rhs.days
        }
    }

    /// 最值得放大倒数的一个：倒数日优先，其次是 60 天内到的日子
    static func spotlight(_ items: [Anniversary]) -> AnniversaryInfo? {
        let upcoming = sorted(items).filter { $0.countsDown }
        return upcoming.first { $0.isCountdown } ?? upcoming.first { $0.days <= 60 }
    }
}

enum AnniversaryStyle {
    static let gradient = LinearGradient(
        colors: [Color(hex: 0xFF9A8B), Color(hex: 0xFF6F91), Color(hex: 0xC471ED)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 可以选的颜色（第一个空的是主题色）
    static let palette = ["", "FF6F91", "F2994A", "E8B63C", "6CC57C", "4FB5C9", "5B8DEF", "9B7BE0", "B5836B"]

    static func color(_ hex: String?) -> Color {
        guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return Theme.accentColor }
        return Color(hex: value)
    }

    /// 编辑时可以选的表情，另外也可以输入任意一个
    static let emojis = ["💕", "💍", "🎂", "🎁", "✈️", "🚄", "🏠", "🎓", "🐱", "🌹", "🌸", "🎄", "🎉", "⭐️", "🌙", "☀️", "🍰", "🍜", "🎬", "🎮", "📷", "💼", "🏖️", "⛰️"]
}

/// 纪念日的图标：照片或者表情，圆形
struct AnniversaryIcon: View {
    let info: AnniversaryInfo
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let mediaId = info.anniversary.iconMediaId {
                RemoteImage(mediaId: mediaId, thumb: true, maxPixel: size * 3)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Text(info.emoji)
                    .font(.system(size: size * 0.5))
                    .frame(width: size, height: size)
            }
        }
    }
}

/// 倒数的圆环，里面放图标
struct CountdownRing<Content: View>: View {
    let progress: Double
    let tint: Color
    var lineWidth: CGFloat = 6
    @ViewBuilder let content: Content
    @State private var shown: Double

    init(progress: Double, tint: Color, lineWidth: CGFloat = 6, animated: Bool = true, @ViewBuilder content: () -> Content) {
        self.progress = progress
        self.tint = tint
        self.lineWidth = lineWidth
        self.content = content()
        _shown = State(initialValue: animated ? 0 : progress)
    }

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            content
        }
        .padding(lineWidth / 2)
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { shown = progress } }
        .onChange(of: progress) { _, value in withAnimation(.easeOut(duration: 0.5)) { shown = value } }
    }
}

/// “我们”页上放大的倒数：距离某一天还有几天，圆环是已经等了的比例
struct CountdownSpotlight: View {
    let info: AnniversaryInfo

    var body: some View {
        HStack(spacing: 18) {
            CountdownRing(progress: info.progress, tint: info.tint, lineWidth: 8) {
                AnniversaryIcon(info: info, size: 52)
            }
            .frame(width: 92, height: 92)
            VStack(alignment: .leading, spacing: 4) {
                Text("距离「\(info.anniversary.title)」")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Paper.inkSoft)
                    .lineLimit(1)
                if info.isToday {
                    Text("就是今天 🎉")
                        .font(.system(size: 30, weight: .bold, design: .serif))
                        .foregroundStyle(info.tint)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("还有").font(.subheadline).foregroundStyle(Paper.ink)
                        Text("\(info.days)")
                            .font(.system(size: 42, weight: .bold, design: .serif))
                            .foregroundStyle(info.tint)
                            .contentTransition(.numericText())
                        Text("天").font(.headline).foregroundStyle(Paper.ink)
                    }
                }
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(Paper.inkSoft)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .paperCard(padding: 16, radius: 24)
    }

    private var footnote: String {
        if info.anniversary.kind == "yearly" { return info.subtitle }
        if info.isToday { return Format.fullDate.string(from: info.nextDate) }
        return "已经等了 \(info.waitedDays) 天 · \(Int((info.progress * 100).rounded()))%"
    }
}

/// 撒彩纸（复用抽卡的粒子）
struct ConfettiView: UIViewRepresentable {
    let fire: Bool

    func makeUIView(context: Context) -> ParticleView { ParticleView() }

    func updateUIView(_ view: ParticleView, context: Context) {
        guard fire else { return }
        let colors: [UInt32] = [0xFF6F91, 0xFFC75F, 0x6FA8FF, 0xB18CF2, 0x6CC57C]
        view.fire(colors: colors.map { UIColor(hex: $0) }, level: 4)
    }
}

/// 纪念日：最近的一个放在最上面倒数，下面是全部；当天的会撒彩纸
struct AnniversariesView: View {
    @Environment(AppModel.self) private var app
    let model: UsModel
    @State private var adding = false
    @State private var detail: Anniversary?
    @State private var celebrate = false

    var body: some View {
        let infos = AnniversaryInfo.sorted(model.anniversaries)
        let hero = infos.first { $0.countsDown }
        ScrollView {
            VStack(spacing: 14) {
                if let hero {
                    Button { detail = hero.anniversary } label: { AnniversaryHero(info: hero) }
                        .buttonStyle(.plain)
                }
                if infos.isEmpty {
                    ContentUnavailableView {
                        Label("还没有纪念日", systemImage: "calendar.badge.plus")
                    } description: {
                        Text("生日、恋爱纪念日、倒数见面的日子……到了那天大橘会在聊天里提醒你们")
                    } actions: {
                        Button("添加一个") { adding = true }.buttonStyle(.glassProminent)
                    }
                    .padding(.top, 40)
                }
                ForEach(infos, id: \.anniversary.id) { info in
                    Button { detail = info.anniversary } label: { AnniversaryLine(info: info).paperCard(padding: 0, radius: 20) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("删除", systemImage: "trash", role: .destructive) { Task { await delete(info.anniversary) } }
                        }
                }
            }
            .padding(16)
            .animation(.snappy, value: model.anniversaries)
        }
        .background(Paper.canvas)
        .overlay {
            ConfettiView(fire: celebrate)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
        .paperList()
        .navigationTitle("纪念日")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建", systemImage: "plus") { adding = true }
            }
        }
        .sheet(isPresented: $adding) {
            AnniversaryEditor(anniversary: nil) { Task { await model.reloadAnniversaries(app) } }
        }
        .sheet(item: $detail) { anniversary in
            AnniversaryDetailSheet(anniversary: anniversary) { Task { await model.reloadAnniversaries(app) } }
        }
        .task {
            if model.anniversaries.isEmpty { await model.reloadAnniversaries(app) }
            if model.anniversaries.map({ AnniversaryInfo($0) }).contains(where: \.showsToday) {
                try? await Task.sleep(for: .milliseconds(400))
                celebrate = true
                Haptics.success()
            }
        }
    }

    private func delete(_ anniversary: Anniversary) async {
        try? await app.api.delete("v1/anniversaries/\(anniversary.id)")
        await model.reloadAnniversaries(app)
    }
}

/// 最近的纪念日：大号倒数
private struct AnniversaryHero: View {
    let info: AnniversaryInfo

    var body: some View {
        HStack(spacing: 18) {
            CountdownRing(progress: info.progress, tint: .white, lineWidth: 7) {
                AnniversaryIcon(info: info, size: 64)
            }
            .frame(width: 100, height: 100)
            VStack(alignment: .leading, spacing: 6) {
                Text(info.isCountdown ? "距离「\(info.anniversary.title)」" : info.anniversary.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                if info.isToday {
                    Text("就是今天 🎉").font(.system(size: 30, weight: .heavy, design: .rounded))
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(info.days)")
                            .font(.system(size: 46, weight: .heavy, design: .rounded))
                            .contentTransition(.numericText())
                        Text(info.isFuture ? "天后" : "天了").font(.headline)
                    }
                }
                Text(info.isCountdown && !info.isToday ? "已经等了 \(info.waitedDays) 天" : info.subtitle).font(.caption).opacity(0.9)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(heroBackground, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: info.tint.opacity(0.3), radius: 14, y: 8)
    }

    /// 选了颜色就用那个颜色的渐变，没选用原来的粉紫渐变
    private var heroBackground: AnyShapeStyle {
        guard let color = info.anniversary.color, !color.isEmpty else { return AnyShapeStyle(AnniversaryStyle.gradient) }
        let tint = info.tint
        return AnyShapeStyle(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

/// 纪念日的一行：倒数的画圆环，已经过去的只显示图标
struct AnniversaryLine: View {
    let info: AnniversaryInfo

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if info.countsDown {
                    CountdownRing(progress: info.progress, tint: info.tint, lineWidth: 3.5) {
                        AnniversaryIcon(info: info, size: 34)
                    }
                } else {
                    AnniversaryIcon(info: info, size: 40)
                        .background(Paper.inset, in: Circle())
                }
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.anniversary.title).font(.headline).foregroundStyle(Paper.ink).lineLimit(1)
                Text(info.subtitle).font(.caption).foregroundStyle(Paper.inkSoft).lineLimit(1)
            }
            Spacer(minLength: 6)
            if info.showsToday {
                Text("就是今天").font(.system(.headline, design: .serif)).foregroundStyle(info.tint)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    if !info.countsDown { Text("已经").font(.caption).foregroundStyle(Paper.inkSoft) }
                    Text("\(info.days)")
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundStyle(info.countsDown ? info.tint : Paper.ink)
                    Text(info.countsDown ? "天后" : "天").font(.caption).foregroundStyle(Paper.inkSoft)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// 分享用的卡片：也是详情页顶部的那张
struct AnniversaryShareCard: View {
    let info: AnniversaryInfo
    /// 渲染成图片时 RemoteImage 来不及加载，照片图标事先取好传进来
    var iconImage: UIImage?

    var body: some View {
        VStack(spacing: 12) {
            if let iconImage {
                Image(uiImage: iconImage).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 2))
            } else if info.anniversary.iconMediaId != nil {
                AnniversaryIcon(info: info, size: 72).overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 2))
            } else {
                Text(info.emoji).font(.system(size: 56))
            }
            Text(info.isCountdown ? "距离「\(info.anniversary.title)」" : info.anniversary.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            if info.showsToday {
                Text("就是今天").font(.system(size: 44, weight: .heavy, design: .rounded))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(info.isFuture ? "还有" : "已经").font(.headline)
                    Text("\(info.days)").font(.system(size: 64, weight: .heavy, design: .rounded))
                    Text("天").font(.headline)
                }
            }
            Text(info.subtitle).font(.subheadline).opacity(0.9)
            Text("漫长悄悄话")
                .font(.caption2.weight(.semibold))
                .opacity(0.7)
                .padding(.top, 6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
        .background(background, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var background: AnyShapeStyle {
        guard let color = info.anniversary.color, !color.isEmpty else { return AnyShapeStyle(AnniversaryStyle.gradient) }
        return AnyShapeStyle(LinearGradient(colors: [info.tint.opacity(0.75), info.tint], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

/// 点开一个纪念日：大卡片、几个数字、接下来几次的日期，可以分享、编辑、删除
struct AnniversaryDetailSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let anniversary: Anniversary
    let onChanged: () -> Void
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var shareImage: Image?
    @State private var iconImage: UIImage?

    var body: some View {
        let info = AnniversaryInfo(anniversary)
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    AnniversaryShareCard(info: info, iconImage: iconImage)
                    let rows = facts(info)
                    VStack(spacing: 0) {
                        ForEach(rows) { fact in
                            HStack {
                                Text(fact.label).foregroundStyle(.secondary)
                                Spacer()
                                Text(fact.value).fontWeight(.semibold)
                            }
                            .font(.subheadline)
                            .padding(.vertical, 10)
                            if fact.id != rows.last?.id { Divider() }
                        }
                    }
                    .cardStyle()
                    if anniversary.kind == "yearly" {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("接下来的几次").font(.headline)
                            ForEach(1 ..< 4, id: \.self) { offset in
                                if let date = Format.calendar.date(byAdding: .year, value: offset, to: info.nextDate) {
                                    HStack {
                                        Text(Format.fullDate.string(from: date))
                                        Spacer()
                                        Text(Format.weekday.string(from: date)).foregroundStyle(.secondary)
                                    }
                                    .font(.subheadline)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
                    }
                    if let shareImage {
                        ShareLink(item: shareImage, preview: SharePreview(anniversary.title, image: shareImage)) {
                            Label("分享这张卡片", systemImage: "square.and.arrow.up")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    }
                }
                .padding(16)
            }
            .background(Paper.canvas)
            .paperList()
            .navigationTitle(anniversary.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("编辑", systemImage: "pencil") { editing = true }
                        Button("删除", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .sheet(isPresented: $editing) {
                AnniversaryEditor(anniversary: anniversary) {
                    onChanged()
                    dismiss()
                }
            }
            .confirmationDialog("删除「\(anniversary.title)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    Task {
                        try? await app.api.delete("v1/anniversaries/\(anniversary.id)")
                        onChanged()
                        dismiss()
                    }
                }
            }
            .task {
                if let mediaId = anniversary.iconMediaId {
                    iconImage = await MediaCache.shared.image(mediaId, thumb: true, maxPixel: 300)
                }
                shareImage = renderShareImage(info)
            }
        }
    }

    private struct Fact: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    private func facts(_ info: AnniversaryInfo) -> [Fact] {
        let original = Format.parseDay(anniversary.date) ?? Date()
        let today = Format.calendar.startOfDay(for: Date())
        let since = Format.daysBetween(original, today)
        var rows: [Fact] = []
        if anniversary.kind == "yearly" {
            rows.append(Fact(label: "下一次", value: "\(Format.fullDate.string(from: info.nextDate)) \(Format.weekday.string(from: info.nextDate))"))
            rows.append(Fact(label: "还有", value: info.isToday ? "就是今天" : "\(info.days) 天"))
            if let years = info.years, years > 0 { rows.append(Fact(label: "那天是", value: "第 \(years) 个")) }
            rows.append(Fact(label: "最早那天", value: Format.fullDate.string(from: original)))
            if since > 0 { rows.append(Fact(label: "已经过了", value: "\(since) 天")) }
        } else {
            rows.append(Fact(label: info.isCountdown ? "目标日" : (info.isCountUp ? "从这天算起" : "日期"), value: "\(Format.fullDate.string(from: original)) \(Format.weekday.string(from: original))"))
            rows.append(Fact(label: info.isFuture ? "还有" : "已经", value: info.showsToday ? "就是今天" : "\(info.days) 天"))
            if info.isCountdown && info.isFuture {
                rows.append(Fact(label: "从哪天开始数", value: Format.fullDate.string(from: info.startDate)))
                rows.append(Fact(label: "已经等了", value: "\(info.waitedDays) 天（\(Int((info.progress * 100).rounded()))%）"))
            }
            if info.days >= 14 { rows.append(Fact(label: "大约", value: "\(info.days / 7) 周")) }
            if info.days >= 60 { rows.append(Fact(label: "或者", value: "\(info.days / 30) 个月")) }
        }
        return rows
    }

    private func renderShareImage(_ info: AnniversaryInfo) -> Image? {
        let renderer = ImageRenderer(content: AnniversaryShareCard(info: info, iconImage: iconImage).frame(width: 340).padding(20))
        renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage: $0) }
    }
}

/// 新建、编辑纪念日：三种类型（每年、倒数日、正数日），图标可以是任意表情或一张照片，还能选颜色
struct AnniversaryEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let anniversary: Anniversary?
    let onSaved: () -> Void

    @State private var title = ""
    @State private var date = Date()
    @State private var kind = "yearly"
    @State private var startDate = Date()
    @State private var emoji = "💕"
    @State private var customEmoji = ""
    @State private var iconMediaId: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var color = ""
    @State private var pinned = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            PaperForm {
                Section {
                    preview
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                Section {
                    Picker("类型", selection: $kind) {
                        Text("每年").tag("yearly")
                        Text("倒数日").tag("countdown")
                        Text("正数日").tag("once")
                    }
                    .pickerStyle(.segmented)
                    TextField(titlePlaceholder, text: $title)
                    if kind == "once" {
                        // 正数日从今天或以前开始数；以前记的将来的日子也照样能改
                        DatePicker("从哪天开始数", selection: $date, in: ...max(Date(), originalDate), displayedComponents: .date)
                    } else {
                        DatePicker(kind == "countdown" ? "目标日" : "日期", selection: $date, displayedComponents: .date)
                    }
                    if kind == "countdown" {
                        DatePicker("从哪天开始数", selection: $startDate, in: ...max(date, startDate), displayedComponents: .date)
                    }
                    Toggle("置顶", isOn: $pinned)
                } footer: {
                    Text(footer)
                }
                Section("图标") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(AnniversaryStyle.emojis, id: \.self) { item in
                            Text(item)
                                .font(.title2)
                                .frame(width: 44, height: 44)
                                .background(iconMediaId == nil && emoji == item ? tint.opacity(0.22) : Color.clear, in: Circle())
                                .onTapGesture {
                                    Haptics.selection()
                                    emoji = item
                                    customEmoji = ""
                                    iconMediaId = nil
                                }
                        }
                    }
                    .padding(.vertical, 4)
                    TextField("或者输入任意一个表情", text: $customEmoji)
                        .onChange(of: customEmoji) { _, value in
                            // 只留第一个字（一个表情可能由好几个码点组成，按字符算就是一个）
                            guard let first = value.first else { return }
                            if value.count > 1 { customEmoji = String(first) }
                            emoji = String(first)
                            iconMediaId = nil
                        }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(uploading ? "照片上传中…" : (iconMediaId == nil ? "用一张照片做图标" : "换一张照片"), systemImage: "photo.circle")
                    }
                    .disabled(uploading)
                    if iconMediaId != nil {
                        Button("不用照片了", systemImage: "xmark.circle", role: .destructive) { iconMediaId = nil }
                    }
                }
                Section("颜色") {
                    HStack(spacing: 10) {
                        ForEach(AnniversaryStyle.palette, id: \.self) { hex in
                            Circle()
                                .fill(AnniversaryStyle.color(hex).gradient)
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if color == hex {
                                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture {
                                    Haptics.selection()
                                    color = hex
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            .paperList()
            .navigationTitle(anniversary == nil ? "新纪念日" : "编辑纪念日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving || uploading)
                }
            }
            .onAppear(perform: fill)
            .onChange(of: kind) { _, value in
                // 换成正数日时，以后的日子改回今天
                if value == "once", date > max(Date(), originalDate) { date = Date() }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await uploadPhoto(item) }
            }
        }
    }

    private var tint: Color { AnniversaryStyle.color(color) }

    private var footer: String {
        switch kind {
        case "countdown": return "倒数到以后的那一天，圆环是已经等了多少；到了那天大橘会在聊天里说一声。"
        case "once": return "从这一天往后数，显示已经多少天，比如在一起、上次见面。"
        default: return "每年这一天都会倒数，当天大橘会在聊天里送上祝福。"
        }
    }

    private var titlePlaceholder: String {
        switch kind {
        case "countdown": return "倒数什么，比如：下次见面"
        case "once": return "正数什么，比如：在一起"
        default: return "名称，比如：她的生日"
        }
    }

    /// 编辑时原来的日期（以前记的正数日可能是将来的日子，日期选择不能把它排除在外）
    private var originalDate: Date {
        anniversary.flatMap { Format.parseDay($0.date) } ?? Date()
    }

    /// 顶上的小样：和列表里一样的圆环和图标
    private var preview: some View {
        let sample = Anniversary(
            id: anniversary?.id ?? "preview", title: title, date: Format.dayKey(date), kind: kind, emoji: emoji, iconMediaId: iconMediaId,
            color: color, startDate: kind == "countdown" ? Format.dayKey(startDate) : nil, pinned: pinned,
            createdBy: app.me?.id ?? "", createdAt: anniversary?.createdAt ?? Date().timeIntervalSince1970 * 1000, updatedAt: 0
        )
        let info = AnniversaryInfo(sample)
        return VStack(spacing: 8) {
            CountdownRing(progress: info.countsDown ? info.progress : 1, tint: tint, lineWidth: 6) {
                AnniversaryIcon(info: info, size: 58)
            }
            .frame(width: 88, height: 88)
            Text(info.headline)
                .font(.system(.headline, design: .serif))
                .foregroundStyle(tint)
        }
        .padding(.vertical, 4)
    }

    private func fill() {
        guard let anniversary else { return }
        title = anniversary.title
        date = Format.parseDay(anniversary.date) ?? Date()
        kind = anniversary.kind
        emoji = anniversary.emoji.isEmpty ? "📅" : anniversary.emoji
        if !AnniversaryStyle.emojis.contains(emoji) { customEmoji = emoji }
        iconMediaId = anniversary.iconMediaId
        color = anniversary.color ?? ""
        startDate = anniversary.startDate.flatMap(Format.parseDay) ?? Format.date(anniversary.createdAt)
        pinned = anniversary.pinned
    }

    /// 选的照片裁成正方形、压小，传上去做图标
    private func uploadPhoto(_ item: PhotosPickerItem) async {
        uploading = true
        defer {
            uploading = false
            photoItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
        let normalized = MediaPrep.normalized(image)
        var square = normalized
        if let cgImage = normalized.cgImage {
            let side = min(cgImage.width, cgImage.height)
            let rect = CGRect(x: (cgImage.width - side) / 2, y: (cgImage.height - side) / 2, width: side, height: side)
            if let cropped = cgImage.cropping(to: rect) { square = UIImage(cgImage: cropped) }
        }
        guard let prepared = MediaPrep.photo(MediaPrep.resized(square, maxSide: 600)) else { return }
        defer { try? FileManager.default.removeItem(at: prepared.fileURL) }
        do {
            let media = try await app.api.upload(meta: prepared.meta, file: prepared.fileURL, filename: prepared.filename, thumb: prepared.thumbnail)
            if let thumb = prepared.thumbnail { MediaCache.shared.store(thumb, id: media.id, thumb: true) }
            if let full = try? Data(contentsOf: prepared.fileURL) { MediaCache.shared.store(full, id: media.id, thumb: false) }
            iconMediaId = media.id
        } catch {
            self.error = "照片没传上去：\(error.localizedDescription)"
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var body: [String: Any] = [
            "title": title.trimmingCharacters(in: .whitespaces),
            "date": Format.dayKey(date),
            "kind": kind,
            "emoji": emoji,
            "color": color,
            "pinned": pinned,
        ]
        body["iconMediaId"] = iconMediaId.map { $0 as Any } ?? NSNull()
        body["startDate"] = kind == "countdown" ? Format.dayKey(min(startDate, date)) : NSNull()
        do {
            if let anniversary {
                _ = try await app.api.send("PATCH", "v1/anniversaries/\(anniversary.id)", body: body)
            } else {
                _ = try await app.api.send("POST", "v1/anniversaries", body: body)
            }
            Haptics.success()
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
