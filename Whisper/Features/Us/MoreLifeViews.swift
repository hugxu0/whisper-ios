import Charts
import PhotosUI
import SwiftUI

// MARK: - 统计

struct StatsView: View {
    @Environment(AppModel.self) private var app
    @State private var year: Int? = Calendar.current.component(.year, from: Date())
    @State private var stats: Stats?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("年份", selection: $year) {
                    Text("全部").tag(Int?.none)
                    ForEach(years, id: \.self) { value in Text(String(value)).tag(Int?.some(value)) }
                }
                .pickerStyle(.segmented)

                if let stats {
                    content(stats)
                } else if loading {
                    ProgressView().padding(40)
                }
            }
            .padding(16)
        }
        .background(Paper.canvas)
        .paperList()
        .navigationTitle(year.map { "\(String($0)) 年度报告" } ?? "聊天统计")
        .task(id: year) { await load() }
    }

    private var years: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 2) ... current)
    }

    private func load() async {
        loading = true
        stats = nil
        defer { loading = false }
        var query: [String: String?] = [:]
        if let year { query["year"] = String(year) }
        stats = try? await app.api.get("v1/stats", query: query)
    }

    @ViewBuilder
    private func content(_ stats: Stats) -> some View {
        let me = app.me?.id ?? ""
        let partner = app.partner?.id ?? ""
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(value: stats.total.formatted(), label: "条消息", icon: "bubble.left.and.bubble.right.fill")
            StatTile(value: "\(stats.activeDays)", label: "天有聊天", icon: "calendar")
            StatTile(value: "\(stats.streaks.longest.days)", label: "最长连续天数", icon: "flame.fill")
            StatTile(value: "\(stats.streaks.current)", label: "当前连续天数", icon: "bolt.heart.fill")
        }

        VStack(alignment: .leading, spacing: 10) {
            Text("谁说得多").font(.headline)
            let mine = stats.bySender[me] ?? 0
            let theirs = stats.bySender[partner] ?? 0
            let total = max(1, mine + theirs)
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    Rectangle().fill(Theme.accentColor.gradient).frame(width: geometry.size.width * CGFloat(mine) / CGFloat(total))
                    Rectangle().fill(Color.pink.gradient)
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            HStack {
                Label("我 \(mine.formatted())", systemImage: "circle.fill").foregroundStyle(Theme.accentColor)
                Spacer()
                Label("\(app.name(partner)) \(theirs.formatted())", systemImage: "circle.fill").foregroundStyle(.pink)
            }
            .font(.caption)
            if let daju = stats.bySender["daju"], daju > 0 {
                Text("大橘插嘴了 \(daju) 次 🐱").font(.caption).foregroundStyle(.secondary)
            }
        }
        .cardStyle()

        if !stats.byMonth.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("每月消息").font(.headline)
                Chart(stats.byMonth, id: \.month) { item in
                    BarMark(x: .value("月份", String(item.month.suffix(2)) + "月"), y: .value("消息", item.count))
                        .foregroundStyle(Theme.accentColor.gradient)
                        .cornerRadius(4)
                }
                .frame(height: 180)
            }
            .cardStyle()
        }

        VStack(alignment: .leading, spacing: 10) {
            Text("一天里什么时候聊得最多").font(.headline)
            Chart(Array(stats.byHour.enumerated()), id: \.offset) { hour, count in
                BarMark(x: .value("时", hour), y: .value("消息", count))
                    .foregroundStyle(Color.purple.gradient)
            }
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) }
            .frame(height: 140)
            if let peak = stats.byHour.enumerated().max(by: { $0.element < $1.element }) {
                Text("最热闹的是 \(peak.offset) 点").font(.caption).foregroundStyle(.secondary)
            }
        }
        .cardStyle()

        if let busiest = stats.busiestDay {
            HStack {
                Image(systemName: "star.circle.fill").font(.title).foregroundStyle(.orange.gradient)
                VStack(alignment: .leading) {
                    Text("聊得最多的一天").font(.subheadline.weight(.semibold))
                    Text("\(busiest.day.replacingOccurrences(of: "-", with: "."))，一共 \(busiest.count) 条").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .cardStyle()
        }

        if !stats.topEmojis.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("最爱用的表情").font(.headline)
                HStack {
                    ForEach(stats.topEmojis.prefix(6), id: \.emoji) { item in
                        VStack {
                            Text(item.emoji).font(.largeTitle)
                            Text("\(item.count)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .cardStyle()
        }

        if !stats.topStickers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("最常发的贴纸").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(stats.topStickers, id: \.media.id) { item in
                            VStack {
                                RemoteImage(mediaId: item.media.id, thumb: false, maxPixel: 200, contentMode: .fit, animated: true)
                                    .frame(width: 64, height: 64)
                                Text("\(item.count) 次").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .cardStyle()
        }

        if let first = stats.firstMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text(year == nil ? "你们的第一条消息" : "这一年的第一条消息").font(.headline)
                Text(Format.fullDateTime.string(from: first.date)).font(.caption).foregroundStyle(.secondary)
                Text("\(first.senderId == app.me?.id ? "我" : app.name(first.senderId))：\(MessagePreview.text(first, app: app))")
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Theme.accentColor)
                .frame(height: 22)
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - 心愿单

struct WishesView: View {
    @Environment(AppModel.self) private var app
    let model: UsModel
    @State private var adding = false
    @State private var newTitle = ""

    var body: some View {
        PaperList {
            let pending = model.wishes.filter { $0.doneAt == nil }
            let done = model.wishes.filter { $0.doneAt != nil }
            if model.wishes.isEmpty {
                ContentUnavailableView("还没有心愿", systemImage: "star", description: Text("写下想一起做的事：看极光、去海边、养一只真的猫……"))
                    .listRowBackground(Color.clear)
            }
            if !pending.isEmpty {
                Section("想一起做") { ForEach(pending) { wishRow($0) } }
            }
            if !done.isEmpty {
                Section("已经做到 🎉") { ForEach(done) { wishRow($0) } }
            }
        }
        .paperList()
        .navigationTitle("心愿单")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("添加", systemImage: "plus") { adding = true } }
        }
        .alert("新的心愿", isPresented: $adding) {
            TextField("想一起做的事", text: $newTitle)
            Button("取消", role: .cancel) { newTitle = "" }
            Button("添加") {
                let title = newTitle.trimmingCharacters(in: .whitespaces)
                newTitle = ""
                guard !title.isEmpty else { return }
                Task {
                    _ = try? await app.api.send("POST", "v1/wishes", body: ["title": title])
                    await model.reloadWishes(app)
                }
            }
        }
    }

    private func wishRow(_ wish: Wish) -> some View {
        HStack(spacing: 12) {
            Button {
                Haptics.success()
                Task {
                    _ = try? await app.api.send("PATCH", "v1/wishes/\(wish.id)", body: ["done": wish.doneAt == nil])
                    await model.reloadWishes(app)
                }
            } label: {
                Image(systemName: wish.doneAt != nil ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(wish.doneAt != nil ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(wish.title).font(.body)
                if let done = wish.doneAt {
                    Text("\(Format.fullDate.string(from: Format.date(done))) 完成").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(wish.createdBy == app.me?.id ? "我" : app.name(wish.createdBy)) 许的愿").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions {
            Button("删除", systemImage: "trash", role: .destructive) {
                Task {
                    try? await app.api.delete("v1/wishes/\(wish.id)")
                    await model.reloadWishes(app)
                }
            }
        }
    }
}

// MARK: - 时光胶囊

struct CapsulesView: View {
    @Environment(AppModel.self) private var app
    let model: UsModel
    @State private var writing = false

    var body: some View {
        PaperList {
            if model.capsules.isEmpty {
                ContentUnavailableView("还没有时光胶囊", systemImage: "envelope", description: Text("写一封给未来的信，到了那天才能打开"))
                    .listRowBackground(Color.clear)
            }
            ForEach(model.capsules) { capsule in
                if capsule.opened {
                    NavigationLink {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(capsule.title).font(.title2.bold())
                                Text("\(capsule.createdBy == app.me?.id ? "我" : app.name(capsule.createdBy)) 写于 \(Format.fullDate.string(from: Format.date(capsule.createdAt)))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(capsule.body ?? "").font(.body).textSelection(.enabled)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .paperList()
                        .navigationTitle("时光胶囊")
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(capsule.title)
                                Text("已于 \(Format.fullDate.string(from: Format.date(capsule.openAt))) 打开").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "envelope.open.fill").foregroundStyle(.purple)
                        }
                    }
                } else {
                    Label {
                        VStack(alignment: .leading) {
                            Text(capsule.title)
                            Text("\(Format.fullDate.string(from: Format.date(capsule.openAt))) 才能打开 · 还有 \(max(0, Format.daysBetween(Date(), Format.date(capsule.openAt)))) 天")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .paperList()
        .navigationTitle("时光胶囊")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("写一封", systemImage: "square.and.pencil") { writing = true } }
        }
        .sheet(isPresented: $writing) { CapsuleEditor(model: model) }
    }
}

private struct CapsuleEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: UsModel
    @State private var title = ""
    @State private var text = ""
    @State private var openAt = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()

    var body: some View {
        NavigationStack {
            PaperForm {
                TextField("标题，比如：给一年后的我们", text: $title)
                DatePicker("打开日期", selection: $openAt, in: Date().addingTimeInterval(86400)..., displayedComponents: .date)
                Section("内容（封存后两个人都看不到，直到那天）") {
                    TextEditor(text: $text).frame(minHeight: 220)
                }
            }
            .paperList()
            .navigationTitle("写给未来")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("封存") {
                        Task {
                            _ = try? await app.api.send("POST", "v1/capsules", body: ["title": title, "body": text, "openAt": Int(openAt.timeIntervalSince1970 * 1000)])
                            await model.reloadCapsules(app)
                            Haptics.success()
                            dismiss()
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
