import SwiftUI

/// 管理自己的贴纸：按分组看，多选后挪到别的分组或删掉；分组可以新建、改名、排序、删除。
/// 贴纸和分组都只属于自己，对方看不到。
struct StickerManagerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// nil 是全部，"" 是未分组，其余是分组 id
    @State private var filter: String?
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var confirmDelete = false
    @State private var working = false
    @State private var toast: Toast?

    private var visible: [Sticker] {
        switch filter {
        case .none: return app.stickers
        case .some(""): return app.stickers.filter { $0.groupId == nil }
        case .some(let id): return app.stickers.filter { $0.groupId == id }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                NavigationLink { StickerGroupsView() } label: {
                    PaperRow(icon: "folder.fill", tint: Theme.accentColor, title: "分组", subtitle: app.stickerGroups.isEmpty ? "还没有分组，建几个方便找" : "\(app.stickerGroups.count) 个分组 · 改名、排序、删除")
                        .paperCard(padding: 0)
                }
                .buttonStyle(.plain)

                filterChips

                if visible.isEmpty {
                    Text(filter == nil ? "还没有贴纸。在聊天里长按图片，选“添加到贴纸”。" : "这一组还没有贴纸")
                        .font(.subheadline)
                        .foregroundStyle(Paper.inkSoft)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        ForEach(visible) { sticker in
                            tile(sticker)
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, selecting ? 80 : 0)
        }
        .background(Paper.canvas.ignoresSafeArea())
        .navigationTitle("管理贴纸")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button(selecting ? "取消" : "选择") {
                    withAnimation(.snappy) {
                        selecting.toggle()
                        selected = []
                    }
                }
                .disabled(visible.isEmpty && !selecting)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting { actionBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .confirmationDialog("删掉选中的 \(selected.count) 个贴纸？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await remove(Array(selected)) } }
        }
        .toast($toast)
        .task { await app.reloadStickers() }
    }

    // MARK: 分组筛选

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("全部 \(app.stickers.count)", value: nil)
                ForEach(app.stickerGroups) { group in
                    chip("\(group.title) \(app.stickers.filter { $0.groupId == group.id }.count)", value: group.id)
                }
                if !app.stickerGroups.isEmpty {
                    chip("未分组 \(app.stickers.filter { $0.groupId == nil }.count)", value: "")
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func chip(_ title: String, value: String?) -> some View {
        let active = filter == value
        return Button {
            withAnimation(.snappy(duration: 0.25)) {
                filter = value
                selected = []
            }
        } label: {
            Text(title)
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Color.white : Paper.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(active ? AnyShapeStyle(Theme.accentColor) : AnyShapeStyle(Paper.card), in: Capsule())
                .overlay(Capsule().strokeBorder(Paper.line, lineWidth: active ? 0 : 0.6))
        }
        .buttonStyle(.plain)
    }

    // MARK: 贴纸格子

    private func tile(_ sticker: Sticker) -> some View {
        let isSelected = selected.contains(sticker.id)
        return RemoteImage(mediaId: sticker.media.id, thumb: false, maxPixel: 240, contentMode: .fit, animated: true)
            .aspectRatio(1, contentMode: .fit)
            .padding(6)
            .background(Paper.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accentColor : Paper.line.opacity(0.6), lineWidth: isSelected ? 2.5 : 0.6)
            }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Theme.accentColor : Color.secondary)
                        .background(Circle().fill(Paper.card).padding(2))
                        .padding(4)
                }
            }
            .scaleEffect(isSelected ? 0.94 : 1)
            .animation(.snappy(duration: 0.2), value: isSelected)
            .contentShape(Rectangle())
            .onTapGesture {
                if !selecting {
                    withAnimation(.snappy) { selecting = true }
                }
                Haptics.selection()
                if isSelected { selected.remove(sticker.id) } else { selected.insert(sticker.id) }
            }
            .contextMenu {
                moveMenu(ids: [sticker.id])
                Button("删除", systemImage: "trash", role: .destructive) { Task { await remove([sticker.id]) } }
            }
    }

    // MARK: 底部操作

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button(selected.count == visible.count ? "全不选" : "全选") {
                selected = selected.count == visible.count ? [] : Set(visible.map(\.id))
            }
            .buttonStyle(.glass)
            Spacer()
            Menu {
                moveMenu(ids: Array(selected))
            } label: {
                Label("移到", systemImage: "folder")
            }
            .buttonStyle(.glass)
            .disabled(selected.isEmpty || working)
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            .buttonStyle(.glass)
            .tint(.red)
            .disabled(selected.isEmpty || working)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func moveMenu(ids: [String]) -> some View {
        Menu("移到分组", systemImage: "folder") {
            Button("不分组", systemImage: "tray") { Task { await move(ids, to: nil) } }
            ForEach(app.stickerGroups) { group in
                Button(group.title) { Task { await move(ids, to: group.id) } }
            }
        }
    }

    private func move(_ ids: [String], to groupId: String?) async {
        guard !ids.isEmpty else { return }
        working = true
        defer { working = false }
        let body: [String: Any] = ["ids": ids, "groupId": groupId.map { $0 as Any } ?? NSNull()]
        do {
            let state: StickerState = try await app.api.post("v1/stickers/move", body)
            app.applyStickers(state)
            selected = []
            Haptics.success()
            toast = Toast(message: "挪好了")
        } catch {
            toast = Toast(message: error.localizedDescription, icon: "exclamationmark.circle")
        }
    }

    private func remove(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            let state: StickerState = try await app.api.post("v1/stickers/remove", ["ids": ids])
            app.applyStickers(state)
            selected = []
            if app.stickers.isEmpty { selecting = false }
            toast = Toast(message: "删掉了 \(ids.count) 个")
        } catch {
            toast = Toast(message: error.localizedDescription, icon: "exclamationmark.circle")
        }
    }
}

/// 贴纸分组：新建、改名、拖动排序、删除（可以选贴纸留下还是一起删）
struct StickerGroupsView: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false
    @State private var draft = ""
    @State private var renaming: StickerGroup?
    @State private var deleting: StickerGroup?
    @State private var toast: Toast?

    var body: some View {
        PaperList {
            Section {
                ForEach(app.stickerGroups) { group in
                    Button {
                        draft = group.title
                        renaming = group
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(Theme.accentColor)
                            Text(group.title).foregroundStyle(Paper.ink)
                            Spacer()
                            Text("\(app.stickers.filter { $0.groupId == group.id }.count) 个").foregroundStyle(Paper.inkSoft)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("删除", role: .destructive) { deleting = group }
                    }
                }
                .onMove { from, to in Task { await reorder(from: from, to: to) } }
            } footer: {
                Text(app.stickerGroups.isEmpty ? "分组只有你自己看得到。" : "点一下改名字，左滑删除，右上角“编辑”后可以拖动排序。")
            }
            Section {
                Button("新建分组", systemImage: "plus.circle.fill") {
                    draft = ""
                    adding = true
                }
            }
        }
        .navigationTitle("贴纸分组")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if app.stickerGroups.count > 1 { EditButton() } }
        .alert("新建分组", isPresented: $adding) {
            TextField("比如：猫猫、表情包", text: $draft)
            Button("取消", role: .cancel) {}
            Button("建好了") { Task { await create() } }
        } message: {
            Text("最多 12 个字")
        }
        .alert("改名字", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("分组名字", text: $draft)
            Button("取消", role: .cancel) { renaming = nil }
            Button("好") {
                if let group = renaming { Task { await rename(group) } }
            }
        }
        .confirmationDialog(
            "删除分组「\(deleting?.title ?? "")」？",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("只删分组，贴纸留下") {
                if let group = deleting { Task { await delete(group, withStickers: false) } }
            }
            Button("分组和里面的贴纸都删掉", role: .destructive) {
                if let group = deleting { Task { await delete(group, withStickers: true) } }
            }
            Button("取消", role: .cancel) { deleting = nil }
        }
        .toast($toast)
    }

    private var title: String { String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12)) }

    private func apply(_ result: () async throws -> StickerState) async {
        do {
            app.applyStickers(try await result())
        } catch {
            toast = Toast(message: error.localizedDescription, icon: "exclamationmark.circle")
        }
    }

    private func create() async {
        guard !title.isEmpty else { return }
        let value = title
        await apply { try await app.api.post("v1/sticker-groups", ["title": value]) }
    }

    private func rename(_ group: StickerGroup) async {
        renaming = nil
        guard !title.isEmpty, title != group.title else { return }
        let value = title
        await apply { try await app.api.patch("v1/sticker-groups/\(group.id)", ["title": value]) }
    }

    private func delete(_ group: StickerGroup, withStickers: Bool) async {
        deleting = nil
        await apply {
            let data = try await app.api.send("DELETE", "v1/sticker-groups/\(group.id)", query: ["withStickers": withStickers ? "1" : "0"])
            return try JSONDecoder().decode(StickerState.self, from: data)
        }
    }

    private func reorder(from: IndexSet, to: Int) async {
        var ids = app.stickerGroups.map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        // 先在本地排好，动画不等网络
        app.stickerGroups = ids.enumerated().compactMap { index, id in
            app.stickerGroups.first { $0.id == id }.map { StickerGroup(id: $0.id, title: $0.title, position: index) }
        }
        await apply { try await app.api.put("v1/sticker-groups/order", ["ids": ids]) }
    }
}
