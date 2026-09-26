import PhotosUI
import SwiftUI

struct MeView: View {
    @Environment(AppModel.self) private var app
    @State private var avatarItem: PhotosPickerItem?
    @State private var editingProfile = false
    @State private var toast: Toast?
    @State private var confirmLogout = false
    @State private var page: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    profileCard

                    PaperGroup(title: "我们") {
                        NavigationLink { TagWallView() } label: {
                            PaperRow(icon: "tag.fill", tint: .pink, title: "标签墙", subtitle: "互相贴的小标签")
                        }
                        NavigationLink { PartnerSettingsView() } label: {
                            PaperRow(icon: "heart.text.square.fill", tint: .red, title: "对 TA 的备注", value: app.partner.map { app.name($0.id) })
                        }
                        NavigationLink { DajuProfileView() } label: {
                            PaperRow(icon: "pawprint.fill", tint: .orange, title: "大橘的名字和头像", value: app.daju?.displayName)
                        }
                    }

                    PaperGroup(title: "设置") {
                        NavigationLink { NotificationSettingsView() } label: {
                            PaperRow(icon: "bell.badge.fill", tint: .red, title: "通知", subtitle: "Bark 推送")
                        }
                        NavigationLink { AppearanceView() } label: {
                            PaperRow(icon: "paintpalette.fill", tint: .purple, title: "外观", subtitle: "主题色、聊天背景、深浅色")
                        }
                        NavigationLink { DevicesView() } label: {
                            PaperRow(icon: "iphone.gen3", tint: .blue, title: "登录设备")
                        }
                        NavigationLink { StorageSettingsView() } label: {
                            PaperRow(icon: "internaldrive.fill", tint: .gray, title: "存储空间")
                        }
                    }

                    PaperGroup(title: "关于") {
                        PaperRow(icon: "info.circle.fill", tint: .teal, title: "版本", value: versionText, chevron: false)
                        PaperRow(icon: "server.rack", tint: .indigo, title: "服务器", value: app.api.baseURL.host ?? "", chevron: false)
                        PaperRow(icon: "dot.radiowaves.left.and.right", tint: app.connection == .connected ? .green : .gray, title: "实时连接", value: connectionText, chevron: false)
                        NavigationLink { AcknowledgementsView() } label: {
                            PaperRow(icon: "heart.fill", tint: .pink, title: "致谢")
                        }
                    }

                    Button {
                        confirmLogout = true
                    } label: {
                        Text("退出登录")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .paperCard(padding: 14)
                    }
                    .buttonStyle(.plain)
                }
                .buttonStyle(.plain)
                .padding(16)
                .padding(.bottom, 12)
            }
            .background(Paper.canvas.ignoresSafeArea())
            .navigationTitle("我")
            .toast($toast)
            .sheet(isPresented: $editingProfile) { ProfileEditor() }
            .confirmationDialog("确定退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) { app.logout() }
            }
            .onChange(of: avatarItem) { _, item in
                guard let item else { return }
                Task { await uploadAvatar(item) }
            }
            .navigationDestination(item: $page) { destination($0) }
            .onAppear { if let next = app.takePageRequest(for: "me") { page = next } }
            .onChange(of: app.pageRequest) { if let next = app.takePageRequest(for: "me") { page = next } }
        }
    }

    @ViewBuilder
    private func destination(_ name: String) -> some View {
        switch name {
        case "tags": TagWallView()
        case "partner": PartnerSettingsView()
        case "daju-profile": DajuProfileView()
        case "notifications": NotificationSettingsView()
        case "appearance": AppearanceView()
        case "devices": DevicesView()
        case "storage": StorageSettingsView()
        default: EmptyView()
        }
    }

    /// 头像、名字、状态、签名；点头像换头像
    private var profileCard: some View {
        HStack(spacing: 16) {
            PhotosPicker(selection: $avatarItem, matching: .images) {
                AvatarView(userId: app.me?.id, size: 72)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Theme.accentColor, in: Circle())
                    }
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.me?.displayName ?? "")
                    .font(.system(.title2, design: .serif).weight(.bold))
                    .foregroundStyle(Paper.ink)
                if let status = app.me?.status, !status.isEmpty {
                    Text(status).font(.subheadline).foregroundStyle(Theme.accentColor)
                }
                if let bio = app.me?.bio, !bio.isEmpty {
                    Text(bio).font(.caption).foregroundStyle(Paper.inkSoft).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button("编辑") { editingProfile = true }
                .buttonStyle(.glass)
        }
        .paperCard(padding: 18, radius: 26)
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(version) (\(build))"
    }

    private var connectionText: String {
        switch app.connection {
        case .connected: return "已连接"
        case .connecting: return "连接中…"
        case .disconnected: return "未连接"
        }
    }

    private func uploadAvatar(_ item: PhotosPickerItem) async {
        defer { avatarItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
        let square = MediaPrep.resized(cropSquare(image), maxSide: 800)
        guard let prepared = MediaPrep.photo(square) else { return }
        do {
            let media = try await app.api.upload(meta: prepared.meta, file: prepared.fileURL, filename: prepared.filename, thumb: prepared.thumbnail)
            if let thumb = prepared.thumbnail { MediaCache.shared.store(thumb, id: media.id, thumb: true) }
            struct Response: Decodable { let user: User }
            let response: Response = try await app.api.put("v1/me/avatar", ["mediaId": media.id])
            app.users[response.user.id] = response.user
            app.me = response.user
            toast = Toast(message: "头像已更新")
        } catch {
            toast = Toast(message: error.localizedDescription, icon: "exclamationmark.circle")
        }
        try? FileManager.default.removeItem(at: prepared.fileURL)
    }

    private func cropSquare(_ image: UIImage) -> UIImage {
        let normalized = MediaPrep.normalized(image)
        guard let cgImage = normalized.cgImage else { return image }
        let side = min(cgImage.width, cgImage.height)
        let rect = CGRect(x: (cgImage.width - side) / 2, y: (cgImage.height - side) / 2, width: side, height: side)
        guard let cropped = cgImage.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped)
    }
}

struct ProfileEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var status = ""
    @State private var bio = ""
    @State private var error: String?

    private let presets = ["在想你", "想贴贴", "要亲亲", "在忙", "在吃饭", "睡觉了", "在路上", "开心", "有点累"]

    var body: some View {
        NavigationStack {
            PaperForm {
                Section("名字") { TextField("名字", text: $name) }
                Section {
                    TextField("现在的状态", text: $status)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(presets, id: \.self) { preset in
                                Button(preset) { status = preset }
                                    .buttonStyle(.bordered)
                                    .tint(status == preset ? Theme.accentColor : .gray)
                            }
                        }
                    }
                } header: {
                    Text("状态")
                } footer: {
                    Text("状态会显示在 TA 的聊天标题下面。")
                }
                Section("签名") { TextField("一句话介绍自己", text: $bio, axis: .vertical) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .paperList()
            .navigationTitle("编辑资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await save() } } }
            }
            .onAppear {
                name = app.me?.displayName ?? ""
                status = app.me?.status ?? ""
                bio = app.me?.bio ?? ""
            }
        }
    }

    private func save() async {
        struct Response: Decodable { let user: User }
        do {
            let response: Response = try await app.api.patch("v1/me", ["displayName": name, "status": status, "bio": bio])
            app.users[response.user.id] = response.user
            app.me = response.user
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 标签墙：两个人都能往任意一方的墙上贴标签、点赞
struct TagWallView: View {
    @Environment(AppModel.self) private var app
    @State private var owner = ""
    @State private var adding = false
    @State private var text = ""

    private struct Response: Decodable { let user: User }

    var body: some View {
        let user = app.user(owner)
        ScrollView {
            VStack(spacing: 18) {
                Picker("", selection: $owner) {
                    if let me = app.me { Text("我的墙").tag(me.id) }
                    if let partner = app.partner { Text("\(app.name(partner.id)) 的墙").tag(partner.id) }
                }
                .pickerStyle(.segmented)

                if let user, !user.tags.isEmpty {
                    FlowLayout(spacing: 10) {
                        ForEach(user.tags.sorted { $0.likes > $1.likes }) { tag in
                            Button {
                                Task { await like(tag) }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(tag.text).font(.subheadline.weight(.medium))
                                    if tag.likes > 0 {
                                        Text("♥ \(tag.likes)").font(.caption2.bold()).opacity(0.85)
                                    }
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Theme.tagColor(tag.colorIndex).gradient, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Text("\(tag.createdBy == app.me?.id ? "我" : app.name(tag.createdBy)) 贴的")
                                Button("撕掉", systemImage: "trash", role: .destructive) { Task { await remove(tag) } }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ContentUnavailableView("墙上还空着", systemImage: "tag", description: Text(owner == app.me?.id ? "让 TA 来给你贴几个标签吧" : "给 TA 贴一个标签吧"))
                }
            }
            .padding(16)
        }
        .paperList()
        .navigationTitle("标签墙")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("贴一个", systemImage: "plus") { adding = true } }
        }
        .alert("贴一个标签", isPresented: $adding) {
            TextField("比如：最可爱", text: $text)
            Button("取消", role: .cancel) { text = "" }
            Button("贴上") { Task { await add() } }
        }
        .onAppear { if owner.isEmpty { owner = app.partner?.id ?? app.me?.id ?? "" } }
    }

    private func apply(_ user: User) {
        app.users[user.id] = user
        if user.id == app.me?.id { app.me = user }
    }

    private func like(_ tag: ProfileTag) async {
        Haptics.tap()
        if let response: Response = try? await app.api.post("v1/users/\(owner)/tags/\(tag.id)/like") { apply(response.user) }
    }

    private func remove(_ tag: ProfileTag) async {
        guard let data = try? await app.api.send("DELETE", "v1/users/\(owner)/tags/\(tag.id)"),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return }
        apply(response.user)
    }

    private func add() async {
        let value = text.trimmingCharacters(in: .whitespaces)
        text = ""
        guard !value.isEmpty else { return }
        if let response: Response = try? await app.api.post("v1/users/\(owner)/tags", ["text": String(value.prefix(20)), "colorIndex": Int.random(in: 0 ..< Theme.tagColors.count)]) {
            apply(response.user)
            Haptics.success()
        }
    }
}

/// 自动换行排列（标签墙）
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        // 有明确宽度时占满整行（标签从左排起）；宽度不定时按内容算
        return CGSize(width: width.isFinite ? width : maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct PartnerSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var alias = ""

    var body: some View {
        PaperForm {
            Section {
                TextField("备注名，比如：小旭老公", text: $alias)
            } footer: {
                Text("只在你这边显示，TA 看不到。")
            }
        }
        .paperList()
        .navigationTitle("对 TA 的备注")
        .onAppear { alias = app.settings.mine["partnerAlias"]?.stringValue ?? "" }
        .onDisappear {
            let value = alias.trimmingCharacters(in: .whitespaces)
            if value != (app.settings.mine["partnerAlias"]?.stringValue ?? "") {
                Task { await app.setSetting("partnerAlias", .string(value), shared: false) }
            }
        }
    }
}

struct DajuProfileView: View {
    @Environment(AppModel.self) private var app
    @State private var name = ""
    @State private var avatarItem: PhotosPickerItem?

    private struct Response: Decodable { let user: User }

    var body: some View {
        PaperForm {
            Section {
                HStack {
                    Spacer()
                    PhotosPicker(selection: $avatarItem, matching: .images) {
                        AvatarView(userId: "daju", size: 96)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            Section("名字") {
                TextField("大橘", text: $name)
                Button("保存名字") {
                    Task {
                        if let response: Response = try? await app.api.patch("v1/users/daju", ["displayName": name]) {
                            app.users["daju"] = response.user
                        }
                    }
                }
            }
        }
        .paperList()
        .navigationTitle("大橘")
        .onAppear { name = app.daju?.displayName ?? "大橘" }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task {
                defer { avatarItem = nil }
                guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                      let prepared = MediaPrep.photo(MediaPrep.resized(image, maxSide: 800)),
                      let media = try? await app.api.upload(meta: prepared.meta, file: prepared.fileURL, filename: prepared.filename, thumb: prepared.thumbnail) else { return }
                if let response: Response = try? await app.api.patch("v1/users/daju", ["avatarMediaId": media.id]) {
                    app.users["daju"] = response.user
                }
            }
        }
    }
}

/// Bark 推送设置
struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var targets: [PushTarget] = []
    @State private var input = ""
    @State private var toast: Toast?

    private struct TargetList: Decodable { let targets: [PushTarget] }
    private struct TargetResponse: Decodable { let target: PushTarget }
    private struct TestResponse: Decodable { let sent: Int }

    var body: some View {
        PaperList {
            Section {
                ForEach(targets) { target in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(target.label.isEmpty ? "Bark" : target.label)
                            Text("\(target.server.replacingOccurrences(of: "https://", with: "")) · \(target.keyHint)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { target.enabled }, set: { value in Task { await setEnabled(target, value) } }))
                            .labelsHidden()
                    }
                    .swipeActions {
                        Button("删除", systemImage: "trash", role: .destructive) {
                            Task {
                                try? await app.api.delete("v1/push-targets/\(target.id)")
                                await load()
                            }
                        }
                    }
                }
            } header: {
                Text("推送目标")
            } footer: {
                Text("App 不在前台时，新消息和提醒通过 Bark 推给你。正在看聊天的时候不会推送。")
            }
            Section {
                TextField("粘贴 Bark 推送地址", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("添加") { Task { await add() } }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("在 Bark App 首页复制推送地址，粘贴到这里。")
            }
            Section {
                Button("发一条测试推送") { Task { await test() } }
            }
        }
        .paperList()
        .navigationTitle("通知")
        .toast($toast)
        .task { await load() }
    }

    private func load() async {
        if let response: TargetList = try? await app.api.get("v1/push-targets") { targets = response.targets }
    }

    private func add() async {
        do {
            let _: TargetResponse = try await app.api.post("v1/push-targets", ["input": input.trimmingCharacters(in: .whitespaces), "label": UIDevice.current.name])
            input = ""
            await load()
            toast = Toast(message: "已添加")
        } catch {
            toast = Toast(message: error.localizedDescription, icon: "exclamationmark.circle")
        }
    }

    private func setEnabled(_ target: PushTarget, _ enabled: Bool) async {
        let _: TargetResponse? = try? await app.api.patch("v1/push-targets/\(target.id)", ["enabled": enabled])
        await load()
    }

    private func test() async {
        if let response: TestResponse = try? await app.api.post("v1/push-targets/test") {
            toast = Toast(message: response.sent > 0 ? "已发送，看看手机" : "没有可用的推送目标", icon: response.sent > 0 ? "checkmark.circle.fill" : "exclamationmark.circle")
        }
    }
}

struct AppearanceView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("theme") private var theme = "tangerine"
    @AppStorage("openChatOnLaunch") private var openChatOnLaunch = true

    var body: some View {
        PaperForm {
            Section {
                NavigationLink { ChatWallpaperView() } label: {
                    Label("聊天背景", systemImage: "photo.artframe")
                }
                Toggle(isOn: $openChatOnLaunch) {
                    Label("打开 App 直接进入聊天", systemImage: "bubble.left.and.bubble.right")
                }
            } footer: {
                Text("关掉后打开 App 先停在聊天首页")
            }
            Section("深浅色") {
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("主题色（我发的气泡）") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 14) {
                    ForEach(Theme.palettes) { palette in
                        Button {
                            Haptics.selection()
                            theme = palette.key
                        } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(LinearGradient(colors: palette.gradient.map { Color(uiColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(height: 44)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(theme == palette.key ? Color.primary : Color.clear, lineWidth: 2)
                                    )
                                Text(palette.name).font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .paperList()
        .navigationTitle("外观")
    }
}

struct DevicesView: View {
    @Environment(AppModel.self) private var app
    @State private var sessions: [SessionInfo] = []

    private struct Response: Decodable { let sessions: [SessionInfo] }

    var body: some View {
        PaperList {
            ForEach(sessions) { session in
                HStack {
                    Image(systemName: session.platform == "web" ? "globe" : "iphone.gen3")
                        .foregroundStyle(Theme.accentColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.deviceName.isEmpty ? "未知设备" : session.deviceName)
                        Text("最近活跃 \(Format.relative(session.lastSeenAt))\(session.appVersion.isEmpty ? "" : " · \(session.appVersion)")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if session.current {
                        Text("本机").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    if !session.current {
                        Button("退出", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            Task {
                                try? await app.api.delete("v1/sessions/\(session.id)")
                                await load()
                            }
                        }
                    }
                }
            }
        }
        .paperList()
        .navigationTitle("登录设备")
        .task { await load() }
    }

    private func load() async {
        if let response: Response = try? await app.api.get("v1/sessions") { sessions = response.sessions }
    }
}

struct StorageSettingsView: View {
    @State private var usage: Int64?
    @State private var clearing = false

    var body: some View {
        PaperForm {
            Section {
                HStack {
                    Text("图片和语音缓存")
                    Spacer()
                    Text(usage.map { Format.fileSize($0) } ?? "计算中…").foregroundStyle(.secondary)
                }
                Button("清除缓存", role: .destructive) {
                    clearing = true
                    MediaCache.shared.clearDisk()
                    Task {
                        usage = await MediaCache.shared.diskUsage()
                        clearing = false
                        Haptics.success()
                    }
                }
                .disabled(clearing)
            } footer: {
                Text("清除后再看旧照片会重新下载，聊天记录不受影响。")
            }
        }
        .paperList()
        .navigationTitle("存储空间")
        .task { usage = await MediaCache.shared.diskUsage() }
    }
}

/// 用到的第三方素材
struct AcknowledgementsView: View {
    var body: some View {
        PaperList {
            Section("大橘的 3D 模型") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cute Cartoon Cat Low Poly Game Ready").font(.headline)
                    Text("作者：3Dima（sketchfab.com/Hdjusj）").font(.subheadline)
                    Text("许可：CC BY 4.0（creativecommons.org/licenses/by/4.0）").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .paperList()
        .navigationTitle("致谢")
    }
}
