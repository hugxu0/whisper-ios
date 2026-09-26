import SwiftUI

/// 计划：提醒、备忘、清单。
/// 点圆圈先在本地打勾（带动画），停一会儿再收进“已完成”，请求在后台发，失败了再退回去。
struct PlansView: View {
    @Environment(AppModel.self) private var app
    let model: UsModel
    let focusPlanId: String?
    @State private var kind: String
    @State private var editing: PlanEditTarget?
    @State private var showDone = false
    /// 刚点了完成、还停在原位置显示打勾的
    @State private var finishing: Set<String> = []
    @State private var focused: String?
    @State private var toast: Toast?
    @State private var didSetup = false

    struct PlanEditTarget: Identifiable {
        let id = UUID()
        let plan: Plan?
        let kind: String
    }

    init(model: UsModel, initialKind: String = "reminder", focusPlanId: String? = nil) {
        self.model = model
        self.focusPlanId = focusPlanId
        _kind = State(initialValue: initialKind)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    kindTiles
                    switch kind {
                    case "reminder": reminders
                    case "memo": memos
                    default: todos
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
                .animation(.snappy(duration: 0.35), value: model.plans)
                .animation(.snappy(duration: 0.3), value: finishing)
            }
            .background(Paper.canvas)
            .task { await setup(proxy) }
        }
        .paperList()
        .navigationTitle("计划")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建", systemImage: "plus") { editing = PlanEditTarget(plan: nil, kind: kind) }
            }
        }
        .sheet(item: $editing) { target in
            PlanEditor(plan: target.plan, kind: target.kind) { Task { await model.reloadPlans(app) } }
        }
        .refreshable { await model.reloadPlans(app) }
        .toast($toast)
    }

    // MARK: 顶部三块

    private var kindTiles: some View {
        HStack(spacing: 10) {
            KindTile(title: "提醒", icon: "bell.fill", count: activeCount("reminder"), tint: Color(hex: 0xFF9F43), selected: kind == "reminder") { select("reminder") }
            KindTile(title: "备忘", icon: "note.text", count: model.plans.filter { $0.kind == "memo" }.count, tint: Color(hex: 0xF5B83D), selected: kind == "memo") { select("memo") }
            KindTile(title: "清单", icon: "checklist", count: activeCount("todo"), tint: Color(hex: 0x4DB6AC), selected: kind == "todo") { select("todo") }
        }
        .padding(.top, 6)
    }

    private func select(_ value: String) {
        guard kind != value else { return }
        withAnimation(.snappy(duration: 0.3)) { kind = value }
    }

    private func activeCount(_ kind: String) -> Int {
        model.plans.filter { $0.kind == kind && $0.doneAt == nil }.count
    }

    // MARK: 提醒

    @ViewBuilder
    private var reminders: some View {
        let active = model.plans.filter { $0.kind == "reminder" && ($0.doneAt == nil || finishing.contains($0.id)) }
        if active.isEmpty && !hasDone("reminder") {
            EmptyPlans(kind: "reminder") { editing = PlanEditTarget(plan: nil, kind: "reminder") }
        } else if active.isEmpty {
            Text("提醒都完成了 🎉").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
        }
        ForEach(reminderGroups(active)) { group in
            PlanGroupHeader(title: group.title, tint: group.tint)
            ForEach(group.plans) { plan in row(plan) }
        }
        completed("reminder")
    }

    private struct PlanGroup: Identifiable {
        let title: String
        let tint: Color
        let plans: [Plan]
        var id: String { title }
    }

    /// 按时间分组：已过期、今天、明天、以后、没定时间；置顶的排在组里最前面
    private func reminderGroups(_ plans: [Plan]) -> [PlanGroup] {
        let calendar = Format.calendar
        let now = Date()
        var buckets: [[Plan]] = [[], [], [], [], []]
        let sorted = plans.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return (lhs.remindAt ?? .infinity) < (rhs.remindAt ?? .infinity)
        }
        for plan in sorted {
            guard let at = plan.remindAt.map(Format.date) else {
                buckets[4].append(plan)
                continue
            }
            if at < now && plan.repeatRule == "none" { buckets[0].append(plan) }
            else if calendar.isDateInToday(at) { buckets[1].append(plan) }
            else if calendar.isDateInTomorrow(at) { buckets[2].append(plan) }
            else { buckets[3].append(plan) }
        }
        let titles: [(String, Color)] = [("已过期", .red), ("今天", Color(hex: 0xFF9F43)), ("明天", .blue), ("以后", .secondary), ("没定时间", .secondary)]
        return zip(titles, buckets).compactMap { title, plans in
            plans.isEmpty ? nil : PlanGroup(title: title.0, tint: title.1, plans: plans)
        }
    }

    // MARK: 备忘

    @ViewBuilder
    private var memos: some View {
        let list = model.plans.filter { $0.kind == "memo" }.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.updatedAt > rhs.updatedAt
        }
        if list.isEmpty {
            EmptyPlans(kind: "memo") { editing = PlanEditTarget(plan: nil, kind: "memo") }
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(list) { plan in
                    MemoCard(plan: plan, focused: focused == plan.id)
                        .id(plan.id)
                        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .onTapGesture { editing = PlanEditTarget(plan: plan, kind: plan.kind) }
                        .contextMenu { menu(plan) }
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: 清单

    @ViewBuilder
    private var todos: some View {
        let active = model.plans.filter { $0.kind == "todo" && ($0.doneAt == nil || finishing.contains($0.id)) }.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.updatedAt > rhs.updatedAt
        }
        if active.isEmpty && !hasDone("todo") {
            EmptyPlans(kind: "todo") { editing = PlanEditTarget(plan: nil, kind: "todo") }
        }
        ForEach(active) { plan in row(plan) }
        completed("todo")
    }

    // MARK: 一行

    private func row(_ plan: Plan) -> some View {
        PlanCard(
            plan: plan,
            checked: plan.doneAt != nil || finishing.contains(plan.id),
            focused: focused == plan.id,
            onToggle: { toggle(plan) },
            onToggleItem: { itemId in toggleItem(plan.id, itemId) }
        )
        .id(plan.id)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { editing = PlanEditTarget(plan: plan, kind: plan.kind) }
        .contextMenu { menu(plan) }
        .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity.combined(with: .move(edge: .trailing))))
    }

    @ViewBuilder
    private func menu(_ plan: Plan) -> some View {
        Button(plan.pinned ? "取消置顶" : "置顶", systemImage: plan.pinned ? "pin.slash" : "pin") { Task { await setPinned(plan, !plan.pinned) } }
        Button("编辑", systemImage: "pencil") { editing = PlanEditTarget(plan: plan, kind: plan.kind) }
        Button("删除", systemImage: "trash", role: .destructive) { Task { await delete(plan) } }
    }

    private func hasDone(_ kind: String) -> Bool {
        model.plans.contains { $0.kind == kind && $0.doneAt != nil }
    }

    /// 已完成：默认收起，点标题展开
    @ViewBuilder
    private func completed(_ kind: String) -> some View {
        let done = model.plans
            .filter { $0.kind == kind && $0.doneAt != nil && !finishing.contains($0.id) }
            .sorted { ($0.doneAt ?? 0) > ($1.doneAt ?? 0) }
        if !done.isEmpty {
            Button {
                withAnimation(.snappy(duration: 0.3)) { showDone.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("已完成 \(done.count)")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(showDone ? 90 : 0))
                    Spacer()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showDone {
                ForEach(done.prefix(60)) { plan in
                    row(plan).opacity(0.65)
                }
            }
        }
    }

    // MARK: 操作

    private func setup(_ proxy: ScrollViewProxy) async {
        guard !didSetup else { return }
        didSetup = true
        if model.plans.isEmpty { await model.reloadPlans(app) }
        guard let focusPlanId, let plan = model.plans.first(where: { $0.id == focusPlanId }) else { return }
        kind = plan.kind
        if plan.doneAt != nil { showDone = true }
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation(.snappy) { proxy.scrollTo(focusPlanId, anchor: .center) }
        withAnimation(.easeOut(duration: 0.25)) { focused = focusPlanId }
        try? await Task.sleep(for: .seconds(2.2))
        withAnimation(.easeOut(duration: 0.5)) { focused = nil }
    }

    private func toggle(_ plan: Plan) {
        if finishing.contains(plan.id) {
            // 收起之前又点了一下：取消完成，这时请求还没发
            finishing.remove(plan.id)
            return
        }
        if plan.doneAt == nil {
            finishing.insert(plan.id)
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                guard finishing.contains(plan.id) else { return }
                finishing.remove(plan.id)
                setDone(plan.id, done: true)
                await send(plan.id, body: ["done": true]) { setDone(plan.id, done: false) }
            }
        } else {
            setDone(plan.id, done: false)
            Task { await send(plan.id, body: ["done": false]) { setDone(plan.id, done: true) } }
        }
    }

    private func setDone(_ id: String, done: Bool) {
        guard let index = model.plans.firstIndex(where: { $0.id == id }) else { return }
        model.plans[index].doneAt = done ? Date().timeIntervalSince1970 * 1000 : nil
    }

    private func toggleItem(_ planId: String, _ itemId: String) {
        guard let index = model.plans.firstIndex(where: { $0.id == planId }),
              let itemIndex = model.plans[index].items.firstIndex(where: { $0.id == itemId }) else { return }
        Haptics.selection()
        model.plans[index].items[itemIndex].done.toggle()
        let items = model.plans[index].items.map { ["id": $0.id, "text": $0.text, "done": $0.done] as [String: Any] }
        Task {
            await send(planId, body: ["items": items]) {
                guard let index = model.plans.firstIndex(where: { $0.id == planId }),
                      let itemIndex = model.plans[index].items.firstIndex(where: { $0.id == itemId }) else { return }
                model.plans[index].items[itemIndex].done.toggle()
            }
        }
    }

    private func setPinned(_ plan: Plan, _ pinned: Bool) async {
        guard let index = model.plans.firstIndex(where: { $0.id == plan.id }) else { return }
        model.plans[index].pinned = pinned
        await send(plan.id, body: ["pinned": pinned]) {
            if let index = model.plans.firstIndex(where: { $0.id == plan.id }) { model.plans[index].pinned = !pinned }
        }
    }

    /// 发修改；成功用服务端返回的覆盖本地，失败时撤销本地的改动并提示
    private func send(_ id: String, body: [String: Any], revert: () -> Void) async {
        struct Response: Decodable { let plan: Plan }
        do {
            let response: Response = try await app.api.patch("v1/plans/\(id)", body)
            if let index = model.plans.firstIndex(where: { $0.id == id }) { model.plans[index] = response.plan }
        } catch {
            revert()
            toast = Toast(message: "没有保存成功：\(error.localizedDescription)", icon: "exclamationmark.circle")
        }
    }

    private func delete(_ plan: Plan) async {
        let backup = model.plans
        model.plans.removeAll { $0.id == plan.id }
        do {
            try await app.api.delete("v1/plans/\(plan.id)")
        } catch {
            model.plans = backup
            toast = Toast(message: "没有删掉：\(error.localizedDescription)", icon: "exclamationmark.circle")
        }
    }
}

/// 顶部的分类块：图标、数量、名字
private struct KindTile: View {
    let title: String
    let icon: String
    let count: Int
    let tint: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(selected ? tint : .white)
                        .frame(width: 30, height: 30)
                        .background(selected ? Color.white : tint, in: Circle())
                    Spacer(minLength: 0)
                    Text("\(count)")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .contentTransition(.numericText())
                }
                Text(title).font(.subheadline.weight(.semibold))
            }
            .padding(12)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                selected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Paper.card),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .shadow(color: selected ? tint.opacity(0.3) : .clear, radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
    }
}

private struct PlanGroupHeader: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.footnote.weight(.bold))
            .foregroundStyle(tint)
            .padding(.leading, 4)
            .padding(.top, 6)
    }
}

/// 打勾的圆圈：点了立刻填色、勾弹出来
private struct CheckCircle: View {
    let checked: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(checked ? tint : Color.secondary.opacity(0.45), lineWidth: 2)
                Circle().fill(tint).scaleEffect(checked ? 1 : 0.2).opacity(checked ? 1 : 0)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.white)
                    .scaleEffect(checked ? 1 : 0.3)
                    .opacity(checked ? 1 : 0)
            }
            .frame(width: 26, height: 26)
            .animation(.spring(duration: 0.35, bounce: 0.5), value: checked)
            .contentShape(Circle().inset(by: -10))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: checked) { _, new in new }
    }
}

/// 提醒和清单的卡片
private struct PlanCard: View {
    @Environment(AppModel.self) private var app
    let plan: Plan
    let checked: Bool
    let focused: Bool
    let onToggle: () -> Void
    let onToggleItem: (String) -> Void

    private var tint: Color { plan.kind == "todo" ? Color(hex: 0x4DB6AC) : Color(hex: 0xFF9F43) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CheckCircle(checked: checked, tint: tint, action: onToggle)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if plan.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                    Text(plan.title)
                        .font(.body.weight(.semibold))
                        .strikethrough(checked, color: .secondary)
                        .foregroundStyle(checked ? Color.secondary : Color.primary)
                    Spacer(minLength: 4)
                    OwnerBadge(plan: plan)
                }
                if plan.kind == "reminder", let at = plan.remindAt {
                    let overdue = at < Date().timeIntervalSince1970 * 1000 && plan.doneAt == nil && plan.repeatRule == "none"
                    Label(reminderText(at), systemImage: plan.repeatRule == "none" ? "alarm" : "repeat")
                        .font(.caption)
                        .foregroundStyle(overdue && !checked ? Color.red : Color.secondary)
                }
                if !plan.body.isEmpty {
                    Text(PlanText.preview(plan.body))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if plan.kind == "todo", !plan.items.isEmpty {
                    todoItems
                }
            }
        }
        .padding(14)
        .background(Paper.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.accentColor, lineWidth: focused ? 2.5 : 0)
        )
        .scaleEffect(focused ? 1.02 : 1)
    }

    /// 清单里的前几项可以直接勾
    private var todoItems: some View {
        let done = plan.items.filter(\.done).count
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(plan.items.prefix(5)) { item in
                Button {
                    onToggleItem(item.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.done ? "checkmark.square.fill" : "square")
                            .foregroundStyle(item.done ? tint : Color.secondary)
                            .contentTransition(.symbolEffect(.replace))
                        Text(item.text)
                            .font(.subheadline)
                            .strikethrough(item.done, color: .secondary)
                            .foregroundStyle(item.done ? Color.secondary : Color.primary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if plan.items.count > 5 {
                Text("还有 \(plan.items.count - 5) 项").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                MeterBar(value: Double(done) / Double(max(1, plan.items.count)), color: tint, height: 5)
                Text("\(done)/\(plan.items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private func reminderText(_ at: Double) -> String {
        let text = Format.separator(Format.date(at))
        let repeats = ["daily": "每天", "weekly": "每周", "monthly": "每月", "yearly": "每年"][plan.repeatRule]
        return repeats.map { "\(text) · \($0)" } ?? text
    }
}

/// 备忘的便签卡片
private struct MemoCard: View {
    let plan: Plan
    let focused: Bool

    private static let tints: [UInt32] = [0xFFC93C, 0xFF8A7A, 0x6FA8FF, 0x6CC57C, 0xB18CF2, 0xFFA552]

    private var tint: Color {
        let seed = plan.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hex: Self.tints[seed % Self.tints.count])
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                Text(plan.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if plan.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
            }
            if !plan.body.isEmpty {
                Text(PlanText.preview(plan.body))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
            Spacer(minLength: 0)
            HStack {
                OwnerBadge(plan: plan)
                Spacer(minLength: 0)
                Text(Format.short(Format.date(plan.updatedAt)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background {
            shape.fill(Paper.card)
                .overlay(shape.fill(tint.opacity(0.22)))
        }
        .overlay(shape.strokeBorder(Theme.accentColor, lineWidth: focused ? 2.5 : 0))
    }
}

/// 谁建的：私人、我建的、TA 建的
private struct OwnerBadge: View {
    @Environment(AppModel.self) private var app
    let plan: Plan

    var body: some View {
        let (text, color): (String, Color) = plan.scope == "private"
            ? ("私人", .gray)
            : (plan.ownerId == app.me?.id ? ("我建的", Theme.accentColor) : ("TA 建的", Color(hex: 0xF29CB8)))
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private struct EmptyPlans: View {
    let kind: String
    let onCreate: () -> Void

    var body: some View {
        let (icon, title, detail): (String, String, String) = switch kind {
        case "reminder": ("bell.badge", "还没有提醒", "到点后大橘会在聊天里提醒你们")
        case "memo": ("note.text", "还没有备忘", "想记下的事、清单、攻略都可以放这里")
        default: ("checklist", "还没有清单", "买菜、旅行要带的东西……一项项勾掉")
        }
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.accentColor.gradient)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("新建", systemImage: "plus", action: onCreate)
                .buttonStyle(.glassProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

/// Markdown 正文的纯文字预览
enum PlanText {
    static func preview(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*(#{1,6}\s*|[-*+]\s+(\[[ xX]\]\s*)?|>\s*|\d+\.\s+)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`~]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 新建、编辑计划
struct PlanEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let plan: Plan?
    let onSaved: () -> Void

    @State private var kind: String
    @State private var title = ""
    @State private var bodyText = ""
    @State private var shared = true
    @State private var remindAt = Date().addingTimeInterval(3600)
    @State private var repeatRule = "none"
    @State private var notify = "both"
    @State private var pinned = false
    @State private var items: [PlanItem] = []
    @State private var newItem = ""
    @State private var saving = false
    @State private var error: String?

    init(plan: Plan?, kind: String, onSaved: @escaping () -> Void) {
        self.plan = plan
        self.onSaved = onSaved
        _kind = State(initialValue: plan?.kind ?? kind)
    }

    var body: some View {
        NavigationStack {
            PaperForm {
                if plan == nil {
                    Picker("类型", selection: $kind) {
                        Text("提醒").tag("reminder")
                        Text("备忘").tag("memo")
                        Text("清单").tag("todo")
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    TextField("标题", text: $title)
                    if kind != "todo" {
                        TextField("详细内容（可选，支持 Markdown）", text: $bodyText, axis: .vertical)
                            .lineLimit(3 ... 12)
                    }
                }
                if kind == "todo" {
                    Section("清单") {
                        ForEach($items) { $item in
                            HStack {
                                Button {
                                    item.done.toggle()
                                } label: {
                                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(item.done ? Theme.accentColor : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                TextField("事项", text: $item.text)
                            }
                        }
                        .onDelete { items.remove(atOffsets: $0) }
                        HStack {
                            Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accentColor)
                            TextField("添加一项", text: $newItem)
                                .onSubmit(addItem)
                        }
                    }
                }
                if kind == "reminder" {
                    Section("提醒时间") {
                        DatePicker("时间", selection: $remindAt, displayedComponents: [.date, .hourAndMinute])
                        Picker("重复", selection: $repeatRule) {
                            Text("不重复").tag("none")
                            Text("每天").tag("daily")
                            Text("每周").tag("weekly")
                            Text("每月").tag("monthly")
                            Text("每年").tag("yearly")
                        }
                        if shared {
                            Picker("提醒谁", selection: $notify) {
                                Text("我们俩").tag("both")
                                Text("只提醒我").tag("me")
                                Text("只提醒 TA").tag("partner")
                            }
                        }
                    }
                }
                Section {
                    Toggle("两个人都能看到", isOn: $shared)
                    Toggle("置顶", isOn: $pinned)
                } footer: {
                    Text(kind == "reminder" ? "到点后大橘会在聊天里提醒；私人提醒发在你和大橘的私聊里。" : "关闭后只有你自己能看到。")
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            .paperList()
            .navigationTitle(plan == nil ? "新建" : "编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
            .onAppear(perform: fill)
        }
    }

    private func fill() {
        guard let plan else { return }
        title = plan.title
        bodyText = plan.body
        shared = plan.scope == "shared"
        if let at = plan.remindAt { remindAt = Format.date(at) }
        repeatRule = plan.repeatRule
        notify = plan.notify
        pinned = plan.pinned
        items = plan.items
    }

    private func addItem() {
        let text = newItem.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        items.append(PlanItem(id: UUID().uuidString, text: text, done: false))
        newItem = ""
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if !newItem.isEmpty { addItem() }
        var body: [String: Any] = [
            "title": title.trimmingCharacters(in: .whitespaces),
            "body": bodyText,
            "scope": shared ? "shared" : "private",
            "pinned": pinned,
            "items": items.map { ["id": $0.id, "text": $0.text, "done": $0.done] },
        ]
        if kind == "reminder" {
            body["remindAt"] = Int(remindAt.timeIntervalSince1970 * 1000)
            body["repeat"] = repeatRule
            body["notify"] = notify
        }
        do {
            if let plan {
                _ = try await app.api.send("PATCH", "v1/plans/\(plan.id)", body: body)
            } else {
                body["kind"] = kind
                _ = try await app.api.send("POST", "v1/plans", body: body)
            }
            Haptics.success()
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
