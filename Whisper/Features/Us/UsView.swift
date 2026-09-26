import SwiftUI

/// “我们”页的数据
@Observable
@MainActor
final class UsModel {
    var together: Together?
    var anniversaries: [Anniversary] = []
    var plans: [Plan] = []
    var albums: [Album] = []
    var wishes: [Wish] = []
    var capsules: [TimeCapsule] = []
    var onThisDay: OnThisDay?
    var loaded = false

    private struct AnniversaryList: Decodable { let anniversaries: [Anniversary] }
    private struct PlanList: Decodable { let plans: [Plan] }
    private struct AlbumList: Decodable { let albums: [Album] }
    private struct WishList: Decodable { let wishes: [Wish] }
    private struct CapsuleList: Decodable { let capsules: [TimeCapsule] }

    func load(_ app: AppModel) async {
        let api = app.api
        async let together: Together? = try? api.get("v1/together")
        async let anniversaries: AnniversaryList? = try? api.get("v1/anniversaries")
        async let plans: PlanList? = try? api.get("v1/plans")
        async let albums: AlbumList? = try? api.get("v1/albums")
        async let wishes: WishList? = try? api.get("v1/wishes")
        async let capsules: CapsuleList? = try? api.get("v1/capsules")
        async let onThisDay: OnThisDay? = try? api.get("v1/on-this-day")
        if let value = await together { self.together = value }
        if let value = await anniversaries { self.anniversaries = value.anniversaries }
        if let value = await plans { self.plans = value.plans }
        if let value = await albums { self.albums = value.albums }
        if let value = await wishes { self.wishes = value.wishes }
        if let value = await capsules { self.capsules = value.capsules }
        if let value = await onThisDay { self.onThisDay = value }
        loaded = true
    }

    func reloadPlans(_ app: AppModel) async {
        if let value: PlanList = try? await app.api.get("v1/plans") { plans = value.plans }
    }

    func reloadAnniversaries(_ app: AppModel) async {
        if let value: AnniversaryList = try? await app.api.get("v1/anniversaries") { anniversaries = value.anniversaries }
    }

    func reloadAlbums(_ app: AppModel) async {
        if let value: AlbumList = try? await app.api.get("v1/albums") { albums = value.albums }
    }

    func reloadWishes(_ app: AppModel) async {
        if let value: WishList = try? await app.api.get("v1/wishes") { wishes = value.wishes }
    }

    func reloadCapsules(_ app: AppModel) async {
        if let value: CapsuleList = try? await app.api.get("v1/capsules") { capsules = value.capsules }
    }
}

/// 纪念日的计算：每年重复的算下一次还有几天；一次性的，过去的算已经几天，将来的算还有几天
struct AnniversaryInfo {
    let anniversary: Anniversary
    let days: Int
    let isFuture: Bool
    let years: Int?
    let nextDate: Date

    init(_ anniversary: Anniversary, now: Date = Date()) {
        self.anniversary = anniversary
        let calendar = Format.calendar
        let date = Format.parseDay(anniversary.date) ?? now
        let today = calendar.startOfDay(for: now)
        if anniversary.kind == "yearly" {
            var components = calendar.dateComponents([.month, .day], from: date)
            components.year = calendar.component(.year, from: today)
            var next = calendar.date(from: components) ?? today
            if next < today { components.year = (components.year ?? 0) + 1; next = calendar.date(from: components) ?? today }
            nextDate = next
            days = Format.daysBetween(today, next)
            isFuture = true
            years = (calendar.dateComponents([.year], from: date, to: next).year ?? 0)
        } else {
            nextDate = date
            let difference = Format.daysBetween(today, date)
            isFuture = difference > 0
            days = abs(difference)
            years = nil
        }
    }

    var headline: String {
        if anniversary.kind == "yearly" {
            if days == 0 { return "就是今天" }
            return "还有 \(days) 天"
        }
        if days == 0 { return "就是今天" }
        return isFuture ? "还有 \(days) 天" : "已经 \(days) 天"
    }
}

struct UsView: View {
    @Environment(AppModel.self) private var app
    @State private var model = UsModel()
    @State private var editingSince = false
    @State private var page: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    TogetherHero(together: model.together) { editingSince = true }

                    // 常用：计划、共同相册
                    HStack(spacing: 12) {
                        NavigationLink { PlansView(model: model) } label: { PlansTile(model: model) }
                        NavigationLink { AlbumsView(model: model) } label: { AlbumsTile(model: model) }
                    }
                    .buttonStyle(.plain)
                    .frame(height: 168)

                    VStack(spacing: 10) {
                        NavigationLink { AnniversariesView(model: model) } label: {
                            PaperSectionTitle(title: "纪念日", trailing: model.anniversaries.isEmpty ? "添加" : "全部")
                        }
                        .buttonStyle(.plain)
                        AnniversaryPreview(model: model)
                    }

                    VStack(spacing: 10) {
                        PaperSectionTitle(title: "回忆")
                        NavigationLink { RecollectionView(onThisDay: model.onThisDay) } label: { RecollectionCard(onThisDay: model.onThisDay) }
                            .buttonStyle(.plain)
                    }

                    PaperGroup(title: "更多") {
                        NavigationLink { WishesView(model: model) } label: {
                            PaperRow(icon: "star.fill", tint: .orange, title: "心愿单", subtitle: wishesSubtitle)
                        }
                        NavigationLink { CapsulesView(model: model) } label: {
                            PaperRow(icon: "envelope.fill", tint: .purple, title: "时光胶囊", subtitle: capsuleSubtitle)
                        }
                        NavigationLink { StatsView() } label: {
                            PaperRow(icon: "chart.bar.fill", tint: .blue, title: "聊天统计", subtitle: model.together.map { "一共 \($0.messageCount.formatted()) 条消息" } ?? "年度报告")
                        }
                        NavigationLink { ChatGalleryView(conversationId: "couple") } label: {
                            PaperRow(icon: "photo.on.rectangle.angled", tint: .teal, title: "聊天里的照片", subtitle: model.together.map { "\($0.mediaCount.formatted()) 张照片和视频" } ?? "照片和视频")
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
                .padding(.bottom, 12)
            }
            .background(Paper.canvas.ignoresSafeArea())
            .navigationTitle("我们")
            .refreshable { await model.load(app) }
            .task { if !model.loaded { await model.load(app) } }
            .onChange(of: app.revision["plan"]) { _, _ in Task { await model.reloadPlans(app) } }
            .onChange(of: app.revision["anniversary"]) { _, _ in Task { await model.reloadAnniversaries(app) } }
            .onChange(of: app.revision["album"]) { _, _ in Task { await model.reloadAlbums(app) } }
            .onChange(of: app.revision["wish"]) { _, _ in Task { await model.reloadWishes(app) } }
            .onChange(of: app.revision["capsule"]) { _, _ in Task { await model.reloadCapsules(app) } }
            .onChange(of: app.settings.shared["togetherSince"]) { _, _ in Task { await model.load(app) } }
            .sheet(isPresented: $editingSince) { TogetherSinceEditor() }
            .navigationDestination(item: $page) { destination($0) }
            .onAppear { if let next = app.takePageRequest(for: "us") { page = next } }
            .onChange(of: app.pageRequest) { if let next = app.takePageRequest(for: "us") { page = next } }
        }
    }

    /// 深链直接推入的子页面：根页面的 .task 会随着页面被盖住而取消，所以这里自己保证数据已加载
    private func destination(_ name: String) -> some View {
        Group {
            switch name {
            case "anniversaries": AnniversariesView(model: model)
            case "plans": PlansView(model: model)
            case "albums": AlbumsView(model: model)
            case "stats": StatsView()
            case "wishes": WishesView(model: model)
            case "capsules": CapsulesView(model: model)
            case "gallery": ChatGalleryView(conversationId: "couple")
            default: EmptyView()
            }
        }
        .task { if !model.loaded { await model.load(app) } }
    }

    private var wishesSubtitle: String {
        let done = model.wishes.filter { $0.doneAt != nil }.count
        return model.wishes.isEmpty ? "想一起做的事" : "完成 \(done)/\(model.wishes.count)"
    }

    private var capsuleSubtitle: String {
        let sealed = model.capsules.filter { !$0.opened }
        if let next = sealed.min(by: { $0.openAt < $1.openAt }) {
            return "下一封 \(Format.monthDay.string(from: Format.date(next.openAt))) 打开"
        }
        return model.capsules.isEmpty ? "写给未来的我们" : "\(model.capsules.count) 封已打开"
    }
}

/// 顶部：两个人的头像、在一起的天数（点一下变成一秒一跳的时钟）、离下一个里程碑还有多久
struct TogetherHero: View {
    @Environment(AppModel.self) private var app
    let together: Together?
    let onEdit: () -> Void
    @State private var live = false

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: -12) {
                AvatarView(userId: app.me?.id, size: 64)
                    .overlay(Circle().stroke(Paper.card, lineWidth: 3))
                Image(systemName: "heart.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.pink.gradient)
                    .padding(8)
                    .background(Circle().fill(Paper.card))
                    .zIndex(1)
                    .symbolEffect(.pulse)
                AvatarView(userId: app.partner?.id, size: 64)
                    .overlay(Circle().stroke(Paper.card, lineWidth: 3))
            }
            if let days = together?.daysTogether, let since = together?.togetherSince {
                VStack(spacing: 6) {
                    Text("我们在一起").font(.subheadline).foregroundStyle(Paper.inkSoft)
                    Button {
                        Haptics.selection()
                        withAnimation(.spring(duration: 0.45, bounce: 0.3)) { live.toggle() }
                    } label: {
                        if live {
                            LiveTogetherClock(since: since)
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(days)")
                                    .font(.system(size: 52, weight: .bold, design: .serif))
                                    .foregroundStyle(Theme.accentColor)
                                    .contentTransition(.numericText())
                                Text("天").font(.system(.title3, design: .serif).weight(.semibold)).foregroundStyle(Paper.ink)
                            }
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                    .buttonStyle(.plain)
                    Button(action: onEdit) {
                        Text("\(breakdown(since)) · 从 \(since.replacingOccurrences(of: "-", with: ".")) 开始")
                            .font(.footnote)
                            .foregroundStyle(Paper.inkSoft)
                    }
                    .buttonStyle(.plain)
                }
                milestone(days: days)
            } else {
                Button("设置在一起的日子", systemImage: "calendar.badge.plus", action: onEdit)
                    .buttonStyle(.glassProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .paperCard(padding: 20, radius: 26)
    }

    /// 已经过了几年几个月几天
    private func breakdown(_ since: String) -> String {
        guard let start = Format.parseDay(since) else { return "" }
        let parts = Format.calendar.dateComponents([.year, .month, .day], from: start, to: Format.calendar.startOfDay(for: Date()))
        var text = ""
        if let years = parts.year, years > 0 { text += "\(years) 年 " }
        if let months = parts.month, months > 0 { text += "\(months) 个月 " }
        return text + "\(parts.day ?? 0) 天"
    }

    @ViewBuilder
    private func milestone(days: Int) -> some View {
        let dayMilestones = (together?.milestones ?? []).filter { $0.kind == "days" }
        if let next = dayMilestones.first(where: { !$0.reached }) {
            let previous = dayMilestones.last(where: { $0.reached })?.value ?? 1
            let progress = Double(days - previous) / Double(max(1, next.value - previous))
            VStack(spacing: 7) {
                HStack {
                    Label(next.title, systemImage: "flag.checkered")
                    Spacer()
                    Text("还有 \(max(0, next.value - days)) 天").fontWeight(.semibold)
                }
                .font(.caption)
                .foregroundStyle(Paper.ink)
                MeterBar(value: min(1, max(0.02, progress)), color: Theme.accentColor, height: 6)
            }
            .padding(12)
            .background(Paper.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// 在一起多少小时、分、秒，一秒跳一次
private struct LiveTogetherClock: View {
    let since: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let start = Format.parseDay(since) ?? context.date
            let seconds = max(0, Int(context.date.timeIntervalSince(start)))
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(seconds / 3600)")
                        .font(.system(size: 40, weight: .bold, design: .serif))
                        .foregroundStyle(Theme.accentColor)
                    Text("小时").font(.system(.headline, design: .serif)).foregroundStyle(Paper.ink)
                }
                Text("\(seconds % 3600 / 60) 分 \(seconds % 60) 秒")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Paper.inkSoft)
                    .contentTransition(.numericText())
            }
        }
    }
}

/// 常用：计划。显示还没完成几件、最近的一个提醒
private struct PlansTile: View {
    let model: UsModel

    var body: some View {
        let now = Date().timeIntervalSince1970 * 1000
        let pending = model.plans.filter { $0.doneAt == nil }
        let next = pending
            .filter { $0.kind == "reminder" && ($0.remindAt ?? 0) > now }
            .min { ($0.remindAt ?? 0) < ($1.remindAt ?? 0) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                PaperIcon(systemName: "checklist", tint: Color(hex: 0xE8894A), size: 40)
                Spacer()
                Text("\(pending.count)")
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .foregroundStyle(Paper.ink)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
            Text("计划").font(Paper.title(.headline)).foregroundStyle(Paper.ink)
            if let next, let at = next.remindAt {
                Text("\(Format.separator(Format.date(at))) · \(next.title)")
                    .font(.caption)
                    .foregroundStyle(Paper.inkSoft)
                    .lineLimit(2)
            } else {
                Text(pending.isEmpty ? "提醒、备忘、清单都放这里" : "\(pending.count) 件还没完成")
                    .font(.caption)
                    .foregroundStyle(Paper.inkSoft)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .paperCard(padding: 14)
    }
}

/// 常用：共同相册。和计划一样的纸色方块：图标、照片数量、几本相册、最近什么时候更新
private struct AlbumsTile: View {
    let model: UsModel

    var body: some View {
        let photos = model.albums.reduce(0) { $0 + $1.count }
        let latest = model.albums.compactMap(\.lastPostAt).max()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                PaperIcon(systemName: "photo.stack.fill", tint: Color(hex: 0x5A9E8F), size: 40)
                Spacer()
                Text("\(photos)")
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .foregroundStyle(Paper.ink)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
            Text("共同相册").font(Paper.title(.headline)).foregroundStyle(Paper.ink)
            Text(subtitle(latest))
                .font(.caption)
                .foregroundStyle(Paper.inkSoft)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .paperCard(padding: 14)
    }

    private func subtitle(_ latest: Double?) -> String {
        guard !model.albums.isEmpty else { return "一起记下照片和当时的话" }
        let updated = latest.map { " · \(Format.short(Format.date($0)))更新" } ?? ""
        return "\(model.albums.count) 本相册\(updated)"
    }
}

/// 纪念日：最多三条。倒数的（还没到的）才画圆环，已经过去的只写过了多少天
struct AnniversaryPreview: View {
    let model: UsModel

    var body: some View {
        let infos = Array(AnniversaryInfo.sorted(model.anniversaries).prefix(3))
        VStack(spacing: 0) {
            if infos.isEmpty {
                Text("记下生日、纪念日，到了那天大橘会来祝福")
                    .font(.subheadline)
                    .foregroundStyle(Paper.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            ForEach(infos, id: \.anniversary.id) { info in
                NavigationLink { AnniversariesView(model: model) } label: { AnniversaryLine(info: info) }
                    .buttonStyle(.plain)
                if info.anniversary.id != infos.last?.anniversary.id {
                    Rectangle().fill(Paper.line).frame(height: 0.6).padding(.leading, 70)
                }
            }
        }
        .paperCard(padding: 0)
    }
}

/// 纪念日的一行
struct AnniversaryLine: View {
    let info: AnniversaryInfo

    var body: some View {
        let countdown = info.isFuture || info.isToday
        HStack(spacing: 14) {
            Group {
                if countdown {
                    CountdownRing(progress: info.progress, tint: Theme.accentColor, lineWidth: 3.5) {
                        Text(info.emoji).font(.title3)
                    }
                } else {
                    Text(info.emoji)
                        .font(.title3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Paper.inset, in: Circle())
                }
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.anniversary.title).font(.headline).foregroundStyle(Paper.ink).lineLimit(1)
                Text(info.subtitle).font(.caption).foregroundStyle(Paper.inkSoft).lineLimit(1)
            }
            Spacer(minLength: 6)
            if info.isToday {
                Text("就是今天").font(.system(.headline, design: .serif)).foregroundStyle(Theme.accentColor)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    if !countdown { Text("已经").font(.caption).foregroundStyle(Paper.inkSoft) }
                    Text("\(info.days)")
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundStyle(countdown ? Theme.accentColor : Paper.ink)
                    Text(countdown ? "天后" : "天").font(.caption).foregroundStyle(Paper.inkSoft)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// 回忆的入口：有那年今日就放那天的照片和一句话，没有就是“翻翻旧时光”
struct RecollectionCard: View {
    let onThisDay: OnThisDay?

    var body: some View {
        let year = onThisDay?.years.first
        HStack(spacing: 14) {
            ZStack {
                if let media = year?.media.first {
                    RemoteImage(mediaId: media.media.id, thumb: true, maxPixel: 240)
                } else {
                    LinearGradient(colors: [Color(hex: 0xF6C7A0), Color(hex: 0xE9A5A5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: year == nil ? "shuffle" : "clock.arrow.circlepath")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                if let year {
                    let ago = Format.calendar.component(.year, from: Date()) - year.year
                    Text("\(ago) 年前的今天，聊了 \(year.messageCount) 条")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Paper.ink)
                    Text(year.messages.first.map { MessagePreview.plain($0.text) } ?? "去看看那天吧")
                        .font(.caption)
                        .foregroundStyle(Paper.inkSoft)
                        .lineLimit(1)
                } else {
                    Text("翻翻旧时光").font(.subheadline.weight(.semibold)).foregroundStyle(Paper.ink)
                    Text("随手翻开以前聊得很热闹的一天").font(.caption).foregroundStyle(Paper.inkSoft)
                }
                Text("那年今日 · 翻翻旧时光")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.accentColor)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Paper.inkSoft.opacity(0.6))
        }
        .paperCard(padding: 14)
    }
}

struct TogetherSinceEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            PaperForm {
                DatePicker("在一起的日子", selection: $date, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
            }
            .paperList()
            .navigationTitle("在一起的日子")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            await app.setSetting("togetherSince", .string(Format.dayKey(date)), shared: true)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                if let since = app.settings.shared["togetherSince"]?.stringValue, let value = Format.parseDay(since) { date = value }
            }
        }
        .presentationDetents([.large])
    }
}

struct AlbumCover: View {
    let title: String
    let mediaId: String?
    let count: Int?
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let mediaId {
                    RemoteImage(mediaId: mediaId, thumb: true, maxPixel: 360)
                } else {
                    LinearGradient(colors: [Theme.accentColor.opacity(0.7), Theme.accentColor], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: icon).font(.title).foregroundStyle(.white)
                }
            }
            .frame(width: 110, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(title).font(.caption.weight(.medium)).lineLimit(1)
            if let count { Text("\(count) 张").font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(width: 110)
    }
}
