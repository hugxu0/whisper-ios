import SwiftUI

/// 从“我们”页直接去情侣聊天
@MainActor
enum ChatShortcut {
    /// 打开聊天并跳到某一天
    static func jump(toDay day: String, app: AppModel) {
        app.openConversationRequest = "couple"
        Task { await app.chat("couple").jump(toDay: day) }
    }
}

// MARK: - 回忆（那年今日 + 翻翻旧时光）

/// 回忆：往年的今天放在上面；下面随手翻开以前聊得热闹的一天，点“换一天”再翻
struct RecollectionView: View {
    @Environment(AppModel.self) private var app
    let onThisDay: OnThisDay?
    @State private var day: OnThisDayYear?
    @State private var loading = false
    @State private var empty = false

    private struct Response: Decodable { let day: OnThisDayYear? }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let years = onThisDay?.years, !years.isEmpty {
                    PaperSectionTitle(title: "那年今日", subtitle: Format.monthDay.string(from: Date()))
                    ForEach(years) { year in
                        MemoryDayCard(day: year, title: yearsAgo(year.year))
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    PaperSectionTitle(title: "翻翻旧时光", subtitle: "随手翻一天")
                    Button {
                        Task { await shuffle() }
                    } label: {
                        Label(loading ? "正在翻…" : "换一天", systemImage: "shuffle")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .disabled(loading || empty)
                }
                .padding(.top, 4)
                if let day {
                    MemoryDayCard(day: day, title: agoText(day.date))
                        .id(day.date)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                } else if empty {
                    Text("聊得热闹的日子多起来，这里就能翻到了")
                        .font(.subheadline)
                        .foregroundStyle(Paper.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .paperCard()
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(16)
        }
        .background(Paper.canvas.ignoresSafeArea())
        .navigationTitle("回忆")
        .task { if day == nil { await shuffle() } }
    }

    private func shuffle() async {
        loading = true
        defer { loading = false }
        var query: [String: String?] = [:]
        if let day { query["exclude"] = day.date }
        guard let response: Response = try? await app.api.get("v1/day-recap", query: query) else { return }
        if let next = response.day {
            Haptics.selection()
            withAnimation(.snappy(duration: 0.45)) { day = next }
        } else if day == nil {
            empty = true
        }
    }

    private func yearsAgo(_ year: Int) -> String {
        let current = Format.calendar.component(.year, from: Date())
        return current > year ? "\(current - year) 年前的今天" : "今天"
    }

    private func agoText(_ date: String) -> String {
        guard let value = Format.parseDay(date) else { return date }
        let days = Format.daysBetween(value, Date())
        if days >= 365 { return "\(days / 365) 年前的这一天" }
        if days >= 30 { return "\(days / 30) 个月前的这一天" }
        return "\(days) 天前"
    }
}

/// 一天的回忆：照片、聊天摘录，可以回到那天的聊天
struct MemoryDayCard: View {
    @Environment(AppModel.self) private var app
    let day: OnThisDayYear
    let title: String
    @State private var expanded = false

    var body: some View {
        let messages = expanded ? day.messages : Array(day.messages.prefix(8))
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Paper.title(.headline)).foregroundStyle(Paper.ink)
                    Text(dateText).font(.caption).foregroundStyle(Paper.inkSoft)
                }
                Spacer()
                Text("聊了 \(day.messageCount) 条")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.accentColor.opacity(0.12), in: Capsule())
            }
            if !day.media.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(day.media, id: \.media.id) { item in
                            RemoteImage(mediaId: item.media.id, thumb: true, maxPixel: 420)
                                .frame(width: 124, height: 124)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
            }
            VStack(spacing: 6) {
                ForEach(messages) { message in
                    MiniBubble(message: message)
                }
            }
            .padding(10)
            .background(Paper.inset, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if day.messages.count > 8 && !expanded {
                Button {
                    withAnimation(.snappy) { expanded = true }
                } label: {
                    Text("展开这一天的更多聊天").font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentColor)
            }
            Button {
                ChatShortcut.jump(toDay: day.date, app: app)
            } label: {
                Label("回到那天的聊天", systemImage: "arrow.uturn.backward.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
        .paperCard()
    }

    private var dateText: String {
        guard let date = Format.parseDay(day.date) else { return day.date }
        return "\(Format.fullDate.string(from: date)) \(Format.weekday.string(from: date))"
    }
}

/// 回忆里的一条小气泡：我的在右边，TA 的在左边
private struct MiniBubble: View {
    @Environment(AppModel.self) private var app
    let message: Message

    var body: some View {
        let mine = message.senderId == app.me?.id
        HStack(alignment: .bottom, spacing: 6) {
            if mine { Spacer(minLength: 40) } else { AvatarView(userId: message.senderId, size: 22) }
            content(mine: mine)
            if mine { AvatarView(userId: message.senderId, size: 22) } else { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private func content(mine: Bool) -> some View {
        if message.kind == "sticker", let media = message.media.first {
            RemoteImage(mediaId: media.id, thumb: false, maxPixel: 200, contentMode: .fit, animated: true)
                .frame(width: 70, height: 70)
        } else {
            Text(MessagePreview.text(message, app: app))
                .font(.subheadline)
                .foregroundStyle(mine ? Color.white : Paper.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    mine ? AnyShapeStyle(Theme.accentColor.gradient) : AnyShapeStyle(Paper.card),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
    }
}
