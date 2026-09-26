import SwiftUI

/// 日记本的颜色：桌面、纸、墨水，还有几种胶带
enum DiaryPalette {
    static let desk = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x17140F) : UIColor(hex: 0xF3EBDD) })
    static let paper = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x2A241C) : UIColor(hex: 0xFFFBF2) })
    static let hole = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x120F0B) : UIColor(hex: 0xE9DDC9) })
    static let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xEDE3D1) : UIColor(hex: 0x3B3024) })
    static let tapes: [UInt32] = [0xF7B7A3, 0xA8D5BA, 0xF6D186, 0xB8C0FF, 0xF5A9C8, 0x9ED2F0]

    static func dayTitle(_ day: String) -> String {
        guard let date = Format.parseDay(day) else { return day }
        return Format.monthDayWeek.string(from: date)
    }

    /// 同一天总是同一种胶带颜色
    static func tape(for day: String) -> Color {
        let seed = day.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hex: tapes[seed % tapes.count])
    }
}

/// 日记正文拆成标题和正文：第一行是 Markdown 标题、或者很短的一句，就当标题
struct DiaryText {
    let title: String?
    let body: String

    init(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: "\n")
        guard let first = lines.first else {
            title = nil
            body = trimmed
            return
        }
        let heading = first.trimmingCharacters(in: .whitespaces)
        let isHeading = heading.hasPrefix("#")
        let cleaned = heading.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespaces)
        if lines.count > 1, !cleaned.isEmpty, isHeading || cleaned.count <= 18 {
            title = cleaned
            body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            title = nil
            body = trimmed
        }
    }
}

/// 左边的一列装订孔
struct BindingHoles: View {
    var spacing: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let count = max(1, Int((geometry.size.height - 16) / spacing))
            let used = CGFloat(count - 1) * spacing
            let top = (geometry.size.height - used) / 2
            ForEach(0 ..< count, id: \.self) { index in
                Circle()
                    .fill(DiaryPalette.hole)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.black.opacity(0.06), lineWidth: 1))
                    .position(x: geometry.size.width / 2, y: top + CGFloat(index) * spacing)
            }
        }
        .frame(width: 22)
        .accessibilityHidden(true)
    }
}

/// 斜贴在角上的一小段纸胶带
struct WashiTape: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color.opacity(0.75))
            .overlay(
                HStack(spacing: 5) {
                    ForEach(0 ..< 6, id: \.self) { _ in
                        Capsule().fill(.white.opacity(0.35)).frame(width: 2)
                    }
                }
                .padding(.vertical, 3)
            )
            .frame(width: 62, height: 20)
            .rotationEffect(.degrees(8))
            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            .accessibilityHidden(true)
    }
}

/// 一页纸：纸色背景、左边装订孔、阴影
struct DiaryPaper<Content: View>: View {
    var radius: CGFloat = 18
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            BindingHoles()
                .padding(.leading, 6)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(DiaryPalette.paper)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
        )
    }
}

//// 大橘日记：一页一页的笔记本
struct DiaryView: View {
    @Environment(AppModel.self) private var app
    @State private var diaries: [DajuDiary] = []
    @State private var hasMore = false
    @State private var writing = false
    @State private var toast: Toast?

    private struct Page: Decodable {
        let diaries: [DajuDiary]
        let hasMore: Bool
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                if diaries.isEmpty {
                    ContentUnavailableView("还没有日记", systemImage: "book.closed", description: Text("大橘每天晚上会写一篇"))
                        .padding(.top, 60)
                }
                ForEach(diaries) { diary in
                    NavigationLink { DiaryPageView(diary: diary) } label: {
                        DiaryListCard(diary: diary)
                    }
                    .buttonStyle(.plain)
                }
                if hasMore {
                    Button("更早的日记") { Task { await load(more: true) } }
                        .buttonStyle(.glass)
                        .padding(.vertical, 8)
                }
            }
            .padding(16)
        }
        .background(DiaryPalette.desk.ignoresSafeArea())
        .paperList()
        .navigationTitle("大橘日记")
        .toast($toast)
        .toolbar {
            if app.features.daju {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await writeToday() }
                    } label: {
                        if writing { ProgressView() } else { Label("写今天的", systemImage: "pencil.and.scribble") }
                    }
                    .disabled(writing)
                }
            }
        }
        .task { await load(more: false) }
        .onChange(of: app.revision["diary"]) { _, _ in Task { await load(more: false) } }
    }

    private func load(more: Bool) async {
        var query: [String: String?] = ["limit": "30"]
        if more, let last = diaries.last { query["before"] = last.day }
        guard let page: Page = try? await app.api.get("v1/daju/diaries", query: query) else { return }
        diaries = more ? diaries + page.diaries : page.diaries
        hasMore = page.hasMore
    }

    private func writeToday() async {
        writing = true
        defer { writing = false }
        do {
            // 日记按作息日算：早上 6 点前还算前一天
            let now = Date()
            let day = Format.calendar.component(.hour, from: now) < 6 ? now.addingTimeInterval(-86_400) : now
            _ = try await app.api.send("POST", "v1/daju/diaries/generate", body: ["day": Format.dayKey(day)])
            await load(more: false)
            Haptics.success()
        } catch {
            toast = Toast(message: error.localizedDescription, icon: "exclamationmark.circle")
        }
    }
}

private struct DiaryListCard: View {
    let diary: DajuDiary

    var body: some View {
        let text = DiaryText(diary.content)
        DiaryPaper {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(DiaryPalette.dayTitle(diary.day))
                        .font(.system(.footnote, design: .serif).weight(.semibold))
                        .foregroundStyle(DiaryPalette.ink.opacity(0.6))
                    Spacer()
                }
                if let title = text.title {
                    Text(title)
                        .font(.system(.title3, design: .serif).weight(.bold))
                        .foregroundStyle(DiaryPalette.ink)
                        .lineLimit(2)
                }
                Text(MessagePreview.plain(text.body.replacingOccurrences(of: "#", with: "")))
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(DiaryPalette.ink.opacity(0.75))
                    .lineLimit(3)
                    .lineSpacing(5)
                HStack {
                    Spacer()
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.orange.opacity(0.45))
                        .rotationEffect(.degrees(-14))
                }
            }
            .padding(.vertical, 18)
            .padding(.leading, 8)
            .padding(.trailing, 18)
        }
        .overlay(alignment: .topTrailing) {
            WashiTape(color: DiaryPalette.tape(for: diary.day))
                .offset(x: -18, y: -8)
        }
    }
}

/// 一篇日记：一整页纸，标题、日期、正文、落款
struct DiaryPageView: View {
    let diary: DajuDiary

    var body: some View {
        let text = DiaryText(diary.content)
        ScrollView {
            DiaryPaper(radius: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(DiaryPalette.dayTitle(diary.day))
                        .font(.system(.subheadline, design: .serif).weight(.semibold))
                        .foregroundStyle(DiaryPalette.ink.opacity(0.6))
                    if let title = text.title {
                        Text(title)
                            .font(.system(.title, design: .serif).weight(.bold))
                            .foregroundStyle(DiaryPalette.ink)
                    }
                    HStack(spacing: 6) {
                        ForEach(0 ..< 3, id: \.self) { _ in
                            Image(systemName: "pawprint.fill").font(.system(size: 9))
                        }
                    }
                    .foregroundStyle(Color.orange.opacity(0.5))
                    MarkdownText(text: text.body, bodyFont: .system(.body, design: .serif), lineSpacing: 9)
                        .foregroundStyle(DiaryPalette.ink)
                        .textSelection(.enabled)
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            Text("—— 本喵")
                                .font(.system(.callout, design: .serif).italic())
                                .foregroundStyle(DiaryPalette.ink.opacity(0.7))
                            Image(systemName: "pawprint.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(Color.orange.opacity(0.35))
                                .rotationEffect(.degrees(-16))
                        }
                    }
                }
                .padding(.vertical, 28)
                .padding(.leading, 12)
                .padding(.trailing, 24)
            }
            .overlay(alignment: .topTrailing) {
                WashiTape(color: DiaryPalette.tape(for: diary.day))
                    .offset(x: -24, y: -8)
            }
            .padding(16)
        }
        .background(DiaryPalette.desk.ignoresSafeArea())
        .paperList()
        .navigationTitle("大橘日记")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// 大橘的记忆：可以搜索、修改、删除，也可以教它新的
/// 大橘的记忆：关于你们的画像（按人分组）、近况（到期后不再提）、往事（按日期）
struct MemoriesView: View {
    @Environment(AppModel.self) private var app
    @State private var layer: MemoryLayer = .profile
    @State private var profile: [DajuMemory] = []
    @State private var states: [DajuMemory] = []
    @State private var events: [DajuMemory] = []
    @State private var eventsHasMore = false
    @State private var loadingEvents = false
    @State private var results: [DajuMemory]?
    @State private var query = ""
    @State private var editing: DajuMemory?
    @State private var adding = false

    private struct Page: Decodable {
        let memories: [DajuMemory]
        let hasMore: Bool
    }

    var body: some View {
        PaperList {
            if let results {
                Section("找到 \(results.count) 条") {
                    ForEach(results) { memory in row(memory, showLayer: true) }
                }
            } else {
                Section {
                    Picker("分类", selection: $layer) {
                        ForEach(MemoryLayer.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text(layer.footer)
                }
                switch layer {
                case .profile:
                    ForEach(profileGroups) { group in
                        Section(group.title) {
                            ForEach(group.items) { memory in row(memory, showLayer: false) }
                        }
                    }
                case .state:
                    Section {
                        ForEach(states) { memory in row(memory, showLayer: false) }
                    }
                case .event:
                    Section {
                        ForEach(events) { memory in row(memory, showLayer: false) }
                        if eventsHasMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .task { await loadEvents(more: true) }
                        }
                    }
                }
            }
        }
        .overlay {
            if isEmpty {
                ContentUnavailableView(
                    results == nil ? "还没有" : "没有找到",
                    systemImage: "brain",
                    description: Text(results == nil ? "大橘每天早上会从前一天的聊天里整理，也可以点右上角教它" : "换个关键词试试")
                )
            }
        }
        .searchable(text: $query, prompt: "搜索记忆")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { _, value in if value.isEmpty { results = nil } }
        .paperList()
        .navigationTitle("大橘的记忆")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("教它", systemImage: "plus") { adding = true }
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(isPresented: $adding) {
            MemoryEditor(memory: nil, defaultLayer: layer) { saved in
                Task { await reload() }
                layer = MemoryLayer(rawValue: saved.kind) ?? layer
            }
        }
        .sheet(item: $editing) { memory in
            MemoryEditor(memory: memory, defaultLayer: layer) { saved in replace(saved) }
        }
    }

    private var isEmpty: Bool {
        if let results { return results.isEmpty }
        switch layer {
        case .profile: return profile.isEmpty
        case .state: return states.isEmpty
        case .event: return events.isEmpty && !eventsHasMore
        }
    }

    private struct ProfileGroup: Identifiable {
        let title: String
        let items: [DajuMemory]
        var id: String { title }
    }

    /// 我、对方、两个人各一组
    private var profileGroups: [ProfileGroup] {
        let people = [app.me, app.partner].compactMap { $0 }
        var groups: [ProfileGroup] = []
        for person in people {
            let items = profile.filter { $0.subject == person.id }
            if !items.isEmpty { groups.append(ProfileGroup(title: "关于\(app.name(person.id))", items: items)) }
        }
        let both = profile.filter { memory in !people.contains { $0.id == memory.subject } }
        if !both.isEmpty { groups.append(ProfileGroup(title: "你们俩", items: both)) }
        return groups
    }

    private func row(_ memory: DajuMemory, showLayer: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(memory.content)
                .font(.body)
            HStack(spacing: 6) {
                if showLayer, let layer = MemoryLayer(rawValue: memory.kind) {
                    MemoryTag(text: layer.title, tint: .secondary)
                }
                if memory.kind == "profile", !memory.topic.isEmpty {
                    MemoryTag(text: memory.topic, tint: Theme.accentColor)
                }
                if memory.kind == "state", let until = memory.untilDate {
                    Text("到 \(Format.monthDay.string(from: until))")
                }
                if memory.kind == "event", let day = memory.eventDate, let date = Format.parseDay(day) {
                    Text(Format.fullDate.string(from: date))
                }
                if memory.ownerId != nil {
                    Image(systemName: "lock.fill")
                        .accessibilityLabel("只有你知道")
                }
                Spacer(minLength: 0)
                Text(sourceName(memory.source))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { editing = memory }
        .swipeActions {
            Button("忘掉", systemImage: "trash", role: .destructive) {
                Task { await forget(memory) }
            }
        }
    }

    private func sourceName(_ source: String) -> String {
        switch source {
        case "user": return "你们教的"
        case "legacy": return "旧版记的"
        default: return "大橘记的"
        }
    }

    private func fetch(_ query: [String: String?]) async -> Page? {
        try? await app.api.get("v1/daju/memories", query: query)
    }

    private func reload() async {
        async let profilePage = fetch(["kind": "profile", "limit": "200"])
        async let statePage = fetch(["kind": "state", "limit": "100"])
        async let eventPage = fetch(["kind": "event", "limit": "40"])
        let (loadedProfile, loadedStates, loadedEvents) = await (profilePage, statePage, eventPage)
        if let loadedProfile { profile = loadedProfile.memories }
        if let loadedStates { states = loadedStates.memories }
        if let loadedEvents {
            events = loadedEvents.memories
            eventsHasMore = loadedEvents.hasMore
        }
        if !query.isEmpty { await search() }
    }

    private func loadEvents(more: Bool) async {
        guard !loadingEvents else { return }
        loadingEvents = true
        defer { loadingEvents = false }
        guard let page = await fetch(["kind": "event", "limit": "40", "offset": String(more ? events.count : 0)]) else {
            eventsHasMore = false
            return
        }
        let known = Set(events.map(\.id))
        events = more ? events + page.memories.filter { !known.contains($0.id) } : page.memories
        eventsHasMore = page.hasMore
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = nil
            return
        }
        results = await fetch(["q": text, "limit": "60"])?.memories ?? []
    }

    private func forget(_ memory: DajuMemory) async {
        try? await app.api.delete("v1/daju/memories/\(memory.id)")
        profile.removeAll { $0.id == memory.id }
        states.removeAll { $0.id == memory.id }
        events.removeAll { $0.id == memory.id }
        results?.removeAll { $0.id == memory.id }
    }

    private func replace(_ memory: DajuMemory) {
        for index in profile.indices where profile[index].id == memory.id { profile[index] = memory }
        for index in states.indices where states[index].id == memory.id { states[index] = memory }
        for index in events.indices where events[index].id == memory.id { events[index] = memory }
        if var list = results {
            for index in list.indices where list[index].id == memory.id { list[index] = memory }
            results = list
        }
    }
}

/// 记忆的三层
enum MemoryLayer: String, CaseIterable, Identifiable {
    case profile, state, event

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: return "关于你们"
        case .state: return "近况"
        case .event: return "往事"
        }
    }

    var footer: String {
        switch self {
        case .profile: return "长期成立的事：喜好、习惯、约定。大橘每次回答都会带着这些。"
        case .state: return "一段时间内的情况，过了日期大橘就不再提。"
        case .event: return "发生过的事，聊到相关的话题时大橘会想起来。"
        }
    }
}

private struct MemoryTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// 教大橘记住一件事，或者改一条记忆
struct MemoryEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let memory: DajuMemory?
    let onSave: (DajuMemory) -> Void
    @State private var layer: MemoryLayer
    @State private var content: String
    @State private var subject: String
    @State private var topic: String
    @State private var until: Date
    @State private var eventDate: Date
    @State private var onlyMe = false
    @State private var saving = false
    @State private var errorText: String?

    init(memory: DajuMemory?, defaultLayer: MemoryLayer, onSave: @escaping (DajuMemory) -> Void) {
        self.memory = memory
        self.onSave = onSave
        _layer = State(initialValue: memory.flatMap { MemoryLayer(rawValue: $0.kind) } ?? defaultLayer)
        _content = State(initialValue: memory?.content ?? "")
        _subject = State(initialValue: memory?.subject ?? "both")
        _topic = State(initialValue: memory?.topic ?? "")
        _until = State(initialValue: memory?.untilDate ?? Date().addingTimeInterval(14 * 86_400))
        _eventDate = State(initialValue: memory?.eventDate.flatMap { Format.parseDay($0) } ?? Date())
        _onlyMe = State(initialValue: memory?.ownerId != nil)
    }

    private struct SubjectOption: Identifiable {
        let id: String
        let name: String
    }

    private var subjects: [SubjectOption] {
        [app.me, app.partner].compactMap { $0 }.map { SubjectOption(id: $0.id, name: app.name($0.id)) } + [SubjectOption(id: "both", name: "两个人")]
    }

    private var placeholder: String {
        switch layer {
        case .profile: return "比如：偲偲不吃香菜"
        case .state: return "比如：这周在准备考试"
        case .event: return "比如：第一次一起去看海"
        }
    }

    var body: some View {
        NavigationStack {
            PaperForm {
                if memory == nil {
                    Section {
                        Picker("类型", selection: $layer) {
                            ForEach(MemoryLayer.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text(layer.footer)
                    }
                }
                Section {
                    TextField(placeholder, text: $content, axis: .vertical)
                        .lineLimit(2 ... 6)
                        .onChange(of: content) { _, value in if value.count > 300 { content = String(value.prefix(300)) } }
                }
                if layer != .event {
                    Section {
                        Picker("说的是", selection: $subject) {
                            ForEach(subjects) { Text($0.name).tag($0.id) }
                        }
                        if layer == .profile {
                            TextField("话题（比如：饮食、作息）", text: $topic)
                                .onChange(of: topic) { _, value in if value.count > 10 { topic = String(value.prefix(10)) } }
                        }
                        if layer == .state {
                            DatePicker("有效到", selection: $until, in: Date()..., displayedComponents: .date)
                        }
                    }
                } else if memory == nil {
                    Section {
                        DatePicker("日期", selection: $eventDate, in: ...Date(), displayedComponents: .date)
                    }
                }
                if memory == nil {
                    Section {
                        Toggle("只有我知道", isOn: $onlyMe)
                    } footer: {
                        Text("打开后这条只在你和大橘的私聊里用，对方看不到。")
                    }
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
            }
            .paperList()
            .navigationTitle(memory == nil ? "教大橘记住" : "修改记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(memory == nil ? "记住" : "保存") { Task { await save() } }
                        .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        saving = true
        defer { saving = false }
        struct Response: Decodable { let memory: DajuMemory }
        var body: [String: Any] = ["content": content.trimmingCharacters(in: .whitespacesAndNewlines)]
        if layer != .event { body["subject"] = subject }
        if layer == .profile { body["topic"] = topic.trimmingCharacters(in: .whitespaces) }
        if layer == .state { body["until"] = Format.dayKey(until) }
        do {
            let response: Response
            if let memory {
                response = try await app.api.patch("v1/daju/memories/\(memory.id)", body)
            } else {
                body["kind"] = layer.rawValue
                body["private"] = onlyMe
                if layer == .event { body["eventDate"] = Format.dayKey(eventDate) }
                response = try await app.api.post("v1/daju/memories", body)
            }
            Haptics.success()
            onSave(response.memory)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// 大橘的运行记录：每次回答执行了哪些命令、搜了什么
struct RunsView: View {
    @Environment(AppModel.self) private var app
    @State private var runs: [DajuRun] = []
    @State private var enabled = true

    private struct Response: Decodable {
        let enabled: Bool
        let runs: [DajuRun]
    }

    var body: some View {
        PaperList {
            if !enabled {
                Label("服务器上还没有配置大橘", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(runs) { run in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: icon(run.status)).foregroundStyle(color(run.status))
                        Text(run.question).font(.subheadline).lineLimit(2)
                    }
                    ForEach(Array(run.log.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: entryIcon(entry.type)).font(.caption2).foregroundStyle(.secondary).frame(width: 14)
                            Text(entry.detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    if let error = run.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
                    Text("\(app.name(run.requesterId)) · \(Format.relative(run.createdAt)) · \(run.conversationId == "couple" ? "情侣聊天" : "私聊")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
        }
        .overlay { if runs.isEmpty { ContentUnavailableView("还没有记录", systemImage: "terminal") } }
        .paperList()
        .navigationTitle("运行记录")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let response: Response = try? await app.api.get("v1/daju/runs") else { return }
        runs = response.runs
        enabled = response.enabled
    }

    private func icon(_ status: String) -> String {
        switch status {
        case "done": return "checkmark.circle.fill"
        case "failed": return "xmark.octagon.fill"
        case "running": return "hourglass"
        case "cancelled": return "minus.circle.fill"
        default: return "clock"
        }
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "done": return .green
        case "failed": return .red
        case "running": return .orange
        default: return .secondary
        }
    }

    private func entryIcon(_ type: String) -> String {
        switch type {
        case "command": return "terminal"
        case "search": return "magnifyingglass"
        case "tool": return "wrench.and.screwdriver"
        default: return "timer"
        }
    }
}
