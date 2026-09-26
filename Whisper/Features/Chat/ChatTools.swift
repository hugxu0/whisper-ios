import SwiftUI

/// 搜索聊天记录
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let conversationId: String
    let onSelect: (String) -> Void

    @State private var query = ""
    @State private var kind = "all"
    @State private var results: [Message] = []
    @State private var hasMore = false
    @State private var loading = false
    @State private var searched = false

    private struct Page: Decodable {
        let messages: [Message]
        let hasMore: Bool
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("类型", selection: $kind) {
                    Text("全部").tag("all")
                    Text("文字").tag("text")
                    Text("文件").tag("file")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

                ForEach(results) { message in
                    Button { onSelect(message.id) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            AvatarView(userId: message.senderId, size: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(message.senderId == app.me?.id ? "我" : app.name(message.senderId)).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(Format.short(message.date)).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(highlighted(MessagePreview.text(message, app: app)))
                                    .font(.subheadline)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if hasMore {
                    Button("加载更多") { Task { await search(more: true) } }
                        .frame(maxWidth: .infinity)
                }
            }
            .overlay {
                if loading && results.isEmpty {
                    ProgressView()
                } else if searched && results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if !searched {
                    ContentUnavailableView("搜索聊天记录", systemImage: "magnifyingglass", description: Text("输入关键词，比如“火锅”“生日”"))
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "关键词")
            .onSubmit(of: .search) { Task { await search(more: false) } }
            .onChange(of: kind) { _, _ in if !query.isEmpty { Task { await search(more: false) } } }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return attributed }
        var searchRange = attributed.startIndex ..< attributed.endIndex
        while let range = attributed[searchRange].range(of: keyword, options: .caseInsensitive) {
            attributed[range].foregroundColor = Theme.accentColor
            attributed[range].font = .subheadline.bold()
            searchRange = range.upperBound ..< attributed.endIndex
        }
        return attributed
    }

    private func search(more: Bool) async {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }
        loading = true
        defer { loading = false }
        var parameters: [String: String?] = ["q": keyword, "conversationId": conversationId, "limit": "40"]
        if kind != "all" { parameters["kind"] = kind }
        if more, let last = results.last { parameters["before"] = String(last.seq) }
        do {
            let page: Page = try await app.api.get("v1/search", query: parameters)
            results = more ? results + page.messages : page.messages
            hasMore = page.hasMore
            searched = true
        } catch {
            searched = true
        }
    }
}

/// 按日期跳转：每个月一张日历，颜色越深那天聊得越多
struct JumpToDateView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let conversationId: String
    let onSelect: (String) -> Void

    @State private var counts: [String: Int] = [:]
    @State private var months: [Date] = []
    @State private var loading = true

    private struct Response: Decodable { let days: [ActivityDay] }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(months, id: \.self) { month in
                            MonthGrid(month: month, counts: counts, maxCount: maxCount, onSelect: onSelect)
                                .id(month)
                        }
                    }
                    .padding()
                }
                .onChange(of: months) { _, value in
                    if let last = value.last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle("按日期查找")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private var maxCount: Int { max(1, counts.values.max() ?? 1) }

    private func load() async {
        defer { loading = false }
        guard let response: Response = try? await app.api.get("v1/conversations/\(conversationId)/activity") else { return }
        counts = Dictionary(uniqueKeysWithValues: response.days.map { ($0.day, $0.count) })
        guard let first = response.days.first.flatMap({ Format.parseDay($0.day) }) else { return }
        var cursor = Format.calendar.date(from: Format.calendar.dateComponents([.year, .month], from: first))!
        var result: [Date] = []
        while cursor <= Date() {
            result.append(cursor)
            cursor = Format.calendar.date(byAdding: .month, value: 1, to: cursor)!
        }
        months = result
    }
}

private struct MonthGrid: View {
    let month: Date
    let counts: [String: Int]
    let maxCount: Int
    let onSelect: (String) -> Void

    var body: some View {
        let calendar = Format.calendar
        let days = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        // 周一为第一天
        let offset = (calendar.component(.weekday, from: month) + 5) % 7
        let total = monthTotal(days: days)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Format.yearMonth.string(from: month)).font(.headline)
                Spacer()
                if total > 0 { Text("\(total) 条").font(.caption).foregroundStyle(.secondary) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                ForEach(0 ..< offset, id: \.self) { index in Color.clear.frame(height: 36).id("blank-\(index)") }
                ForEach(1 ... days, id: \.self) { day in
                    let date = calendar.date(byAdding: .day, value: day - 1, to: month)!
                    let key = Format.dayKey(date)
                    let count = counts[key] ?? 0
                    Button {
                        if count > 0 { onSelect(key) }
                    } label: {
                        Text("\(day)")
                            .font(.subheadline.weight(count > 0 ? .semibold : .regular))
                            .foregroundStyle(count > 0 ? (intensity(count) > 0.5 ? Color.white : Color.primary) : Color.secondary.opacity(0.6))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(count > 0 ? Theme.accentColor.opacity(0.15 + 0.85 * intensity(count)) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(count == 0)
                }
            }
        }
    }

    private func intensity(_ count: Int) -> Double {
        min(1, log(Double(count) + 1) / log(Double(maxCount) + 1))
    }

    private func monthTotal(days: Int) -> Int {
        (1 ... days).reduce(0) { total, day in
            let date = Format.calendar.date(byAdding: .day, value: day - 1, to: month)!
            return total + (counts[Format.dayKey(date)] ?? 0)
        }
    }
}

/// 聊天里的照片和视频
struct ChatGalleryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let conversationId: String

    @State private var items: [GalleryItem] = []
    @State private var nextBefore: Int?
    @State private var hasMore = true
    @State private var loading = false
    @State private var viewer: ViewerRequest?

    struct ViewerRequest: Identifiable {
        let id = UUID()
        let index: Int
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button { viewer = ViewerRequest(index: index) } label: {
                        SquareThumbnail(media: item.media)
                    }
                    .buttonStyle(.plain)
                    .onAppear { if index == items.count - 12 { Task { await load() } } }
                }
            }
            if loading { ProgressView().padding() }
        }
        .overlay { if !loading && items.isEmpty { ContentUnavailableView("还没有照片", systemImage: "photo.on.rectangle") } }
        .navigationTitle("照片和视频")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        .task { if items.isEmpty { await load() } }
        .fullScreenCover(item: $viewer) { request in
            MediaViewerRepresentable(items: items.map { MediaViewerItem(media: $0.media, messageId: $0.messageId, senderId: $0.senderId, date: Format.date($0.createdAt)) }, start: request.index)
                .ignoresSafeArea()
        }
    }

    private func load() async {
        guard hasMore, !loading else { return }
        loading = true
        defer { loading = false }
        var query: [String: String?] = ["limit": "90"]
        if let nextBefore { query["before"] = String(nextBefore) }
        guard let page: GalleryPage = try? await app.api.get("v1/conversations/\(conversationId)/gallery", query: query) else { return }
        items += page.items
        nextBefore = page.nextBefore
        hasMore = page.hasMore
    }
}

struct MediaViewerRepresentable: UIViewControllerRepresentable {
    @Environment(AppModel.self) private var app
    let items: [MediaViewerItem]
    let start: Int

    func makeUIViewController(context: Context) -> MediaViewerController {
        MediaViewerController(items: items, startIndex: start, app: app)
    }

    func updateUIViewController(_ controller: MediaViewerController, context: Context) {}
}
