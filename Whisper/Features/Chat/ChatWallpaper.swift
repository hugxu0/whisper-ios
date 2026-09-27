import PhotosUI
import SwiftUI
import UIKit

/// 聊天背景：预设（渐变，可带小图案）或自己的照片。白天用个人设置 chatWallpaper，黑夜用 chatWallpaperDark（没设就跟白天一样），同一个人的几台手机同步。
struct ChatWallpaper: Equatable {
    var kind: String
    var key: String?
    var mediaId: String?
    /// 照片上盖的一层暗色（0–0.6），让气泡更清楚
    var dim: Double

    static func from(_ value: JSONValue?) -> ChatWallpaper? {
        guard let value, case .object = value, let kind = value["kind"]?.stringValue, kind != "none" else { return nil }
        return ChatWallpaper(kind: kind, key: value["key"]?.stringValue, mediaId: value["mediaId"]?.stringValue, dim: value["dim"]?.doubleValue ?? 0.15)
    }

    /// 现在该用哪张：深色模式下用单独设的黑夜背景（kind 为 none 表示黑夜不用背景）；黑夜没单独设就和白天一样
    static func current(_ mine: [String: JSONValue], dark: Bool) -> ChatWallpaper? {
        if dark, let night = mine["chatWallpaperDark"], case .object = night {
            return from(night)
        }
        return from(mine["chatWallpaper"])
    }

    var json: JSONValue {
        .object([
            "kind": .string(kind),
            "key": key.map { JSONValue.string($0) } ?? .null,
            "mediaId": mediaId.map { JSONValue.string($0) } ?? .null,
            "dim": .number(dim),
        ])
    }
}

enum WallpaperPresets {
    struct Preset: Identifiable {
        let key: String
        let name: String
        let light: [UInt32]
        let dark: [UInt32]
        let pattern: String?
        var id: String { key }

        /// 跟随深浅色的两个渐变色
        var colors: [UIColor] {
            zip(light, dark).map { pair in
                let (lightHex, darkHex) = pair
                return UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: darkHex) : UIColor(hex: lightHex) }
            }
        }
    }

    static let all: [Preset] = [
        Preset(key: "peach", name: "蜜桃", light: [0xFFF1E8, 0xFFE0E6], dark: [0x2A1E22, 0x1C1618], pattern: nil),
        Preset(key: "sky", name: "晴空", light: [0xE8F3FF, 0xF4EEFF], dark: [0x162033, 0x1B1729], pattern: nil),
        Preset(key: "mint", name: "薄荷", light: [0xE9FBF3, 0xF2F9E6], dark: [0x14231E, 0x181F16], pattern: nil),
        Preset(key: "lavender", name: "薰衣草", light: [0xF3EDFF, 0xFFEAF6], dark: [0x201A2E, 0x261A25], pattern: nil),
        Preset(key: "hearts", name: "小爱心", light: [0xFFF0F4, 0xFFF7F0], dark: [0x2A1B21, 0x21191B], pattern: "heart.fill"),
        Preset(key: "paws", name: "猫爪", light: [0xFFF6EA, 0xFFF0DF], dark: [0x2A2118, 0x201A14], pattern: "pawprint.fill"),
        Preset(key: "stars", name: "星空", light: [0xEEF0FF, 0xF7F2FF], dark: [0x0F1226, 0x1A1030], pattern: "sparkle"),
    ]

    static func preset(_ key: String?) -> Preset? {
        all.first { $0.key == key }
    }

    /// 平铺的小图案（浅色时深一点、深色时浅一点，都很淡）
    static func patternColor(_ symbol: String) -> UIColor {
        UIColor { trait in
            let dark = trait.userInterfaceStyle == .dark
            let tint = dark ? UIColor.white.withAlphaComponent(0.07) : UIColor.black.withAlphaComponent(0.05)
            let size = CGSize(width: 96, height: 96)
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                let configuration = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                let symbolImage = UIImage(systemName: symbol, withConfiguration: configuration)?.withTintColor(tint, renderingMode: .alwaysOriginal)
                symbolImage?.draw(at: CGPoint(x: 14, y: 16))
                symbolImage?.draw(at: CGPoint(x: 62, y: 62))
            }
            return UIColor(patternImage: image)
        }
    }
}

/// 选聊天背景：白天、黑夜各一张（黑夜可以跟白天一样）
struct ChatWallpaperView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var night = false
    @State private var picking = false
    @State private var uploading = false
    @State private var dim: Double = 0.15

    private static let dayKey = "chatWallpaper"
    private static let nightKey = "chatWallpaperDark"

    private var key: String { night ? Self.nightKey : Self.dayKey }

    /// 黑夜那张有没有单独设
    private var nightIsSet: Bool {
        if case .object = app.settings.mine[Self.nightKey] ?? .null { return true }
        return false
    }

    /// 正在编辑的那一张现在是什么（黑夜跟白天时就是白天那张）
    private var current: ChatWallpaper? {
        night ? ChatWallpaper.current(app.settings.mine, dark: true) : ChatWallpaper.from(app.settings.mine[Self.dayKey])
    }

    var body: some View {
        PaperForm {
            Section {
                Picker("编辑哪一张", selection: $night) {
                    Label("白天", systemImage: "sun.max.fill").tag(false)
                    Label("黑夜", systemImage: "moon.fill").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            } footer: {
                Text("手机切换深色、浅色时自动换成对应的那张。")
            }

            if night {
                Section {
                    Toggle("黑夜和白天用同一张", isOn: Binding(get: { !nightIsSet }, set: { same in Task { await setNightFollowsDay(same) } }))
                }
            }

            if !night || nightIsSet {
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
                        swatch(name: "默认", selected: current == nil) {
                            Color(uiColor: .systemBackground)
                        } action: {
                            Task { await clear() }
                        }
                        ForEach(WallpaperPresets.all) { preset in
                            swatch(name: preset.name, selected: current?.kind == "preset" && current?.key == preset.key) {
                                PresetSwatch(preset: preset)
                            } action: {
                                Task { await save(ChatWallpaper(kind: "preset", key: preset.key, mediaId: nil, dim: 0)) }
                            }
                        }
                        swatch(name: uploading ? "上传中…" : "从相册选", selected: current?.kind == "photo") {
                            ZStack {
                                if let mediaId = current?.kind == "photo" ? current?.mediaId : nil {
                                    RemoteImage(mediaId: mediaId, thumb: false, maxPixel: 300)
                                } else {
                                    Color(uiColor: .tertiarySystemFill)
                                    Image(systemName: "photo.on.rectangle.angled").font(.title2).foregroundStyle(.secondary)
                                }
                            }
                        } action: {
                            picking = true
                        }
                    }
                    .padding(.vertical, 6)
                    // 小样按正在编辑的那张的深浅色显示
                    .environment(\.colorScheme, night ? .dark : .light)
                } footer: {
                    Text("只改你这边的聊天背景，对方看不到")
                }

                if current?.kind == "photo" {
                    Section("照片暗一点，气泡更清楚") {
                        Slider(value: $dim, in: 0 ... 0.6) { editing in
                            guard !editing, var wallpaper = current else { return }
                            wallpaper.dim = dim
                            Task { await save(wallpaper) }
                        }
                    }
                }
            }
        }
        .navigationTitle("聊天背景")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
        }
        .onAppear {
            // 深色模式下打开时先编辑黑夜那张
            night = colorScheme == .dark && nightIsSet
            dim = current?.dim ?? 0.15
        }
        .onChange(of: night) { _, _ in dim = current?.dim ?? 0.15 }
        .sheet(isPresented: $picking) {
            PhotoPicker(limit: 1, filter: .images) { results in
                picking = false
                guard let first = results.first else { return }
                Task { await upload(first) }
            }
            .ignoresSafeArea()
        }
    }

    private func swatch<Content: View>(name: String, selected: Bool, @ViewBuilder content: () -> Content, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            VStack(spacing: 6) {
                Color.clear
                    .aspectRatio(0.62, contentMode: .fit)
                    .overlay { content() }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(selected ? Theme.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2.5 : 1)
                    )
                Text(name).font(.caption).foregroundStyle(Paper.ink)
            }
        }
        .buttonStyle(.plain)
        .disabled(uploading)
    }

    private func save(_ wallpaper: ChatWallpaper) async {
        await app.setSetting(key, wallpaper.json, shared: false)
    }

    /// 选“默认”：白天就是不用背景；黑夜记成 none，表示黑夜不用背景（和“跟白天一样”区分开）
    private func clear() async {
        if night {
            await app.setSetting(Self.nightKey, .object(["kind": .string("none")]), shared: false)
        } else {
            await app.setSetting(Self.dayKey, .null, shared: false)
        }
    }

    /// 黑夜跟白天：删掉黑夜的设置；不跟了：先复制一份白天的，再从这里改
    private func setNightFollowsDay(_ same: Bool) async {
        if same {
            await app.setSetting(Self.nightKey, .null, shared: false)
        } else {
            let day = app.settings.mine[Self.dayKey] ?? .null
            let copy: JSONValue
            if case .object = day { copy = day } else { copy = .object(["kind": .string("none")]) }
            await app.setSetting(Self.nightKey, copy, shared: false)
        }
    }

    private func upload(_ pick: PHPickerResult) async {
        uploading = true
        defer { uploading = false }
        // 背景要铺满整屏，用比聊天照片大的尺寸
        guard let prepared = await MediaPrep.load([pick], photoMaxSide: 2800).first else { return }
        defer { try? FileManager.default.removeItem(at: prepared.fileURL) }
        guard let media = try? await app.api.upload(meta: prepared.meta, file: prepared.fileURL, filename: prepared.filename, thumb: prepared.thumbnail) else { return }
        if let data = try? Data(contentsOf: prepared.fileURL) { MediaCache.shared.store(data, id: media.id, thumb: false) }
        await save(ChatWallpaper(kind: "photo", key: nil, mediaId: media.id, dim: dim))
    }
}

/// 预设背景的小样
struct PresetSwatch: View {
    @Environment(\.colorScheme) private var colorScheme
    let preset: WallpaperPresets.Preset

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: (colorScheme == .dark ? preset.dark : preset.light).map { Color(hex: $0) },
                startPoint: .top,
                endPoint: .bottom
            )
            if let pattern = preset.pattern {
                Image(systemName: pattern)
                    .font(.title3)
                    .foregroundStyle(Color.primary.opacity(0.12))
                    .padding(10)
            }
        }
    }
}
