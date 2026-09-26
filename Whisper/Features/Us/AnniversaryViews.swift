import SwiftUI
import UIKit

extension AnniversaryInfo {
    var isToday: Bool { days == 0 }

    /// 圆环的进度：每年重复的按离上一次过了多少；一次性的将来日子按一年倒数算，过去的满格
    var progress: Double {
        guard anniversary.kind == "yearly" else {
            return isFuture ? max(0.04, 1 - min(1, Double(days) / 365)) : 1
        }
        if days == 0 { return 1 }
        let previous = Format.calendar.date(byAdding: .year, value: -1, to: nextDate) ?? nextDate
        let cycle = max(1, Format.daysBetween(previous, nextDate))
        return max(0.02, 1 - Double(days) / Double(cycle))
    }

    var emoji: String { anniversary.emoji.isEmpty ? "📅" : anniversary.emoji }

    /// 列表里的一行说明
    var subtitle: String {
        let original = Format.parseDay(anniversary.date).map { Format.fullDate.string(from: $0) } ?? anniversary.date
        if anniversary.kind == "yearly" {
            let next = Format.monthDayWeek.string(from: nextDate)
            if let years, years > 0 { return "\(next) · 第 \(years) 个" }
            return next
        }
        return isFuture || days == 0 ? original : "\(original) · 已经过去"
    }

    /// 先排还没到的（越近越前），再排已经过去的
    static func sorted(_ items: [Anniversary]) -> [AnniversaryInfo] {
        items.map { AnniversaryInfo($0) }.sorted { lhs, rhs in
            let left = lhs.isFuture || lhs.isToday
            let right = rhs.isFuture || rhs.isToday
            if left != right { return left }
            if lhs.anniversary.pinned != rhs.anniversary.pinned { return lhs.anniversary.pinned }
            return lhs.days < rhs.days
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
        let hero = infos.first { $0.isFuture || $0.isToday }
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
                        Text("生日、恋爱纪念日、下次见面……到了那天大橘会在聊天里提醒你们")
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
            if model.anniversaries.map({ AnniversaryInfo($0) }).contains(where: \.isToday) {
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
                Text(info.emoji).font(.system(size: 40))
            }
            .frame(width: 100, height: 100)
            VStack(alignment: .leading, spacing: 6) {
                Text(info.anniversary.title)
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
                Text(info.subtitle).font(.caption).opacity(0.9)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(AnniversaryStyle.gradient, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Color(hex: 0xFF6F91).opacity(0.3), radius: 14, y: 8)
    }
}

enum AnniversaryStyle {
    static let gradient = LinearGradient(
        colors: [Color(hex: 0xFF9A8B), Color(hex: 0xFF6F91), Color(hex: 0xC471ED)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// 分享用的卡片：也是详情页顶部的那张
struct AnniversaryShareCard: View {
    let info: AnniversaryInfo

    var body: some View {
        VStack(spacing: 12) {
            Text(info.emoji).font(.system(size: 56))
            Text(info.anniversary.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            if info.isToday {
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
        .background(AnniversaryStyle.gradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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

    var body: some View {
        let info = AnniversaryInfo(anniversary)
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    AnniversaryShareCard(info: info)
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
            .task { shareImage = renderShareImage(info) }
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
            rows.append(Fact(label: "日期", value: "\(Format.fullDate.string(from: original)) \(Format.weekday.string(from: original))"))
            rows.append(Fact(label: info.isFuture ? "还有" : "已经", value: info.isToday ? "就是今天" : "\(info.days) 天"))
            if info.days >= 14 { rows.append(Fact(label: "大约", value: "\(info.days / 7) 周")) }
            if info.days >= 60 { rows.append(Fact(label: "或者", value: "\(info.days / 30) 个月")) }
        }
        return rows
    }

    private func renderShareImage(_ info: AnniversaryInfo) -> Image? {
        let renderer = ImageRenderer(content: AnniversaryShareCard(info: info).frame(width: 340).padding(20))
        renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage: $0) }
    }
}

struct AnniversaryEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let anniversary: Anniversary?
    let onSaved: () -> Void

    @State private var title = ""
    @State private var date = Date()
    @State private var yearly = true
    @State private var emoji = "💕"
    @State private var pinned = false

    private let emojis = ["💕", "🎂", "💍", "✈️", "🏠", "🎓", "🐱", "🌹", "🎄", "⭐️", "📅", "🍰"]

    var body: some View {
        NavigationStack {
            PaperForm {
                Section {
                    TextField("名称，比如：她的生日", text: $title)
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                    Toggle("每年重复", isOn: $yearly)
                    Toggle("置顶", isOn: $pinned)
                } footer: {
                    Text(yearly ? "每年这一天都会倒数，当天大橘会在聊天里送上祝福。" : "过去的日子显示已经多少天，将来的显示还有多少天。")
                }
                Section("图标") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(emojis, id: \.self) { item in
                            Text(item)
                                .font(.title2)
                                .frame(width: 44, height: 44)
                                .background(emoji == item ? Theme.accentColor.opacity(0.2) : Color.clear, in: Circle())
                                .onTapGesture { emoji = item }
                        }
                    }
                }
            }
            .paperList()
            .navigationTitle(anniversary == nil ? "新纪念日" : "编辑纪念日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard let anniversary else { return }
                title = anniversary.title
                date = Format.parseDay(anniversary.date) ?? Date()
                yearly = anniversary.kind == "yearly"
                emoji = anniversary.emoji.isEmpty ? "📅" : anniversary.emoji
                pinned = anniversary.pinned
            }
        }
    }

    private func save() async {
        let body: [String: Any] = ["title": title.trimmingCharacters(in: .whitespaces), "date": Format.dayKey(date), "kind": yearly ? "yearly" : "once", "emoji": emoji, "pinned": pinned]
        if let anniversary {
            _ = try? await app.api.send("PATCH", "v1/anniversaries/\(anniversary.id)", body: body)
        } else {
            _ = try? await app.api.send("POST", "v1/anniversaries", body: body)
        }
        Haptics.success()
        onSaved()
        dismiss()
    }
}
