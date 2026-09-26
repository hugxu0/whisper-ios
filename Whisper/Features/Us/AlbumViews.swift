import PhotosUI
import SwiftUI

// 共同相册：每个相册是一条按时间倒序的“动态”时间线，一条动态是同一次发表的几张照片视频和一段文案。

struct AlbumsView: View {
    @Environment(AppModel.self) private var app
    let model: UsModel
    @State private var creating = false

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                ForEach(model.albums) { album in
                    NavigationLink { AlbumDetailView(album: album, model: model) } label: {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                }
                Button { creating = true } label: { NewAlbumCard() }
                    .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background(Paper.canvas)
        .paperList()
        .navigationTitle("共同相册")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建相册", systemImage: "plus") { creating = true }
            }
        }
        .sheet(isPresented: $creating) {
            AlbumEditorSheet(title: "", note: "", heading: "新建相册") { title, note in
                _ = try? await app.api.send("POST", "v1/albums", body: ["title": title, "note": note])
                await model.reloadAlbums(app)
            }
        }
        .task { if !model.loaded { await model.reloadAlbums(app) } }
    }
}

private struct AlbumCard: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let cover = album.coverMediaId {
                        RemoteImage(mediaId: cover, thumb: true, maxPixel: 520)
                    } else {
                        LinearGradient(colors: [Theme.accentColor.opacity(0.55), Theme.accentColor], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "photo.stack").font(.largeTitle).foregroundStyle(.white)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            Text(album.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(album.postCount ?? album.count) 条动态 · \(album.count) 个片段")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct NewAlbumCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.accentColor.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .background(Theme.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "plus").font(.title2.weight(.semibold))
                        Text("新建相册").font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(Theme.accentColor)
                }
            Text(" ").font(.subheadline)
            Text(" ").font(.caption)
        }
    }
}

/// 相册名称和简介
struct AlbumEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var title: String
    @State var note: String
    let heading: String
    let onSave: (String, String) async -> Void
    @State private var saving = false

    var body: some View {
        NavigationStack {
            PaperForm {
                Section("名称") { TextField("比如：我们的日常", text: $title) }
                Section("简介（可选）") { TextField("写一句话", text: $note, axis: .vertical).lineLimit(2 ... 4) }
            }
            .paperList()
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { return }
                        saving = true
                        Task {
                            await onSave(value, note.trimmingCharacters(in: .whitespacesAndNewlines))
                            dismiss()
                        }
                    }
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let album: Album
    let model: UsModel
    @State private var posts: [AlbumPost] = []
    @State private var loaded = false
    @State private var picking = false
    @State private var pendingPicks: [PHPickerResult] = []
    @State private var composing = false
    @State private var progress: (done: Int, total: Int)?
    @State private var editingCaption: AlbumPost?
    @State private var deleting: AlbumPost?
    @State private var editingAlbum = false
    @State private var confirmDeleteAlbum = false
    @State private var viewer: ViewerRequest?
    @State private var toast: Toast?

    private struct ViewerRequest: Identifiable {
        let id = UUID()
        let items: [MediaViewerItem]
        let index: Int
    }

    private struct PostList: Decodable { let posts: [AlbumPost] }

    private var current: Album { model.albums.first { $0.id == album.id } ?? album }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    header
                    if loaded && posts.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(posts) { post in
                                AlbumPostRow(
                                    post: post,
                                    width: max(0, proxy.size.width - 32),
                                    onOpen: { index in open(post, at: index) },
                                    onEdit: { editingCaption = post },
                                    onDelete: { deleting = post }
                                )
                                if post.id != posts.last?.id {
                                    Divider().padding(.leading, 62)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                        .background(Paper.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    }
                }
                .padding(16)
            }
        }
        .background(Paper.canvas)
        .paperList()
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .toast($toast)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("发表动态", systemImage: "square.and.pencil") { picking = true }
                    .disabled(progress != nil)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("编辑相册", systemImage: "pencil") { editingAlbum = true }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("删除相册", systemImage: "trash", role: .destructive) { confirmDeleteAlbum = true }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: app.revision["album"]) { _, _ in Task { await load() } }
        .sheet(isPresented: $picking) {
            PhotoPicker(limit: 30) { results in
                picking = false
                guard !results.isEmpty else { return }
                pendingPicks = results
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { composing = true }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $composing) {
            PostComposerSheet(count: pendingPicks.count) { caption in
                let picks = pendingPicks
                pendingPicks = []
                Task { await publish(picks, caption: caption) }
            }
        }
        .sheet(item: $editingCaption) { post in
            CaptionEditorSheet(caption: post.caption) { caption in
                _ = try? await app.api.send("PATCH", "v1/albums/\(album.id)/posts/\(post.id)", body: ["caption": caption])
                await load()
            }
        }
        .sheet(isPresented: $editingAlbum) {
            AlbumEditorSheet(title: current.title, note: current.note ?? "", heading: "编辑相册") { title, note in
                _ = try? await app.api.send("PATCH", "v1/albums/\(album.id)", body: ["title": title, "note": note])
                await model.reloadAlbums(app)
            }
        }
        .confirmationDialog("删除这条动态？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let post = deleting else { return }
                deleting = nil
                Task {
                    try? await app.api.delete("v1/albums/\(album.id)/posts/\(post.id)")
                    await load()
                    await model.reloadAlbums(app)
                }
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            Text("照片和视频会从这个相册里移除")
        }
        .confirmationDialog("删除“\(current.title)”？", isPresented: $confirmDeleteAlbum, titleVisibility: .visible) {
            Button("删除相册", role: .destructive) {
                Task {
                    try? await app.api.delete("v1/albums/\(album.id)")
                    await model.reloadAlbums(app)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        }
        .fullScreenCover(item: $viewer) { request in
            MediaViewerRepresentable(items: request.items, start: request.index)
                .ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("我们的动态").font(.headline)
                Spacer()
                Text("\(posts.count) 条 · \(posts.reduce(0) { $0 + $1.media.count }) 个片段")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = current.note, !note.isEmpty {
                Text(note).font(.subheadline).foregroundStyle(.secondary)
            }
            if let progress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(progress.done == 0 ? "正在准备上传…" : "正在上传到共同相册").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(progress.done) / \(progress.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(progress.done), total: Double(max(1, progress.total))).tint(Theme.accentColor)
                }
                .padding(12)
                .background(Theme.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .cardStyle()
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ContentUnavailableView("还没有动态", systemImage: "photo.badge.plus", description: Text("选几张照片或一段视频，写下当时想说的话"))
            Button("发表第一条", systemImage: "square.and.pencil") { picking = true }
                .buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private func open(_ post: AlbumPost, at index: Int) {
        let items = post.media.map { MediaViewerItem(media: $0, messageId: "", senderId: post.addedBy, date: Format.date(post.addedAt)) }
        viewer = ViewerRequest(items: items, index: index)
    }

    private func load() async {
        if let list: PostList = try? await app.api.get("v1/albums/\(album.id)/posts") {
            posts = list.posts
        }
        loaded = true
    }

    /// 一张一张处理、上传，最后作为一条动态发表
    private func publish(_ picks: [PHPickerResult], caption: String) async {
        progress = (0, picks.count)
        var ids: [String] = []
        for (index, pick) in picks.enumerated() {
            for prepared in await MediaPrep.load([pick]) {
                if let media = try? await app.api.upload(meta: prepared.meta, file: prepared.fileURL, filename: prepared.filename, thumb: prepared.thumbnail) {
                    ids.append(media.id)
                    if let thumb = prepared.thumbnail { MediaCache.shared.store(thumb, id: media.id, thumb: true) }
                }
                try? FileManager.default.removeItem(at: prepared.fileURL)
            }
            progress = (index + 1, picks.count)
        }
        if ids.isEmpty {
            toast = Toast(message: "上传失败了，再试一次", icon: "exclamationmark.circle")
        } else if (try? await app.api.send("POST", "v1/albums/\(album.id)/posts", body: ["mediaIds": ids, "caption": caption])) != nil {
            Haptics.success()
        } else {
            toast = Toast(message: "发表失败了，再试一次", icon: "exclamationmark.circle")
        }
        progress = nil
        await load()
        await model.reloadAlbums(app)
    }
}

/// 时间线上的一条动态：左边日期轨，右边作者、文案和照片
private struct AlbumPostRow: View {
    @Environment(AppModel.self) private var app
    let post: AlbumPost
    let width: CGFloat
    let onOpen: (Int) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()

    var body: some View {
        let railWidth: CGFloat = 50
        let bodyWidth = max(0, width - railWidth - 20)
        let date = Format.date(post.addedAt)
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 3) {
                Text(Self.dayFormatter.string(from: date))
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                Text(Self.monthFormatter.string(from: date))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(Theme.accentColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Paper.card, lineWidth: 3))
                    .padding(.top, 5)
                Rectangle()
                    .fill(Theme.accentColor.opacity(0.18))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: railWidth)
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    AvatarView(userId: post.addedBy, size: 22)
                    Text(post.addedBy == app.me?.id ? "我" : app.name(post.addedBy))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Menu {
                        Button("编辑文案", systemImage: "pencil", action: onEdit)
                        Button("删除动态", systemImage: "trash", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 26)
                            .contentShape(Rectangle())
                    }
                }
                if !post.caption.isEmpty {
                    Text(post.caption)
                        .font(.body)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                mediaStrip(bodyWidth)
                Text(Self.timeFormatter.string(from: date))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 14)
            .frame(width: bodyWidth, alignment: .leading)
        }
    }

    private func mediaStrip(_ width: CGFloat) -> some View {
        let gap: CGFloat = 4
        let side = post.media.count == 1 ? min(width * 0.7, 240) : max(1, (width - gap) / 2)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: gap) {
                ForEach(Array(post.media.enumerated()), id: \.element.id) { index, media in
                    Button { onOpen(index) } label: {
                        SquareThumbnail(media: media, maxPixel: side * 3, cornerRadius: 10)
                            .frame(width: side, height: side)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: width, height: side, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if post.media.count > 2 {
                Label("共 \(post.media.count) 张", systemImage: "photo.stack.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct PostComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let count: Int
    let onPublish: (String) -> Void
    @State private var caption = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "photo.stack.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.accentColor)
                        .frame(width: 48, height: 48)
                        .background(Theme.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("已选择 \(count) 个片段").font(.subheadline.weight(.semibold))
                        Text("会作为一条动态发表").font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField("写下这一刻…", text: $caption, axis: .vertical)
                    .lineLimit(4 ... 8)
                    .padding(14)
                    .background(Paper.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Paper.canvas)
            .paperList()
            .navigationTitle("发表动态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发表") {
                        onPublish(caption.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct CaptionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var caption: String
    let onSave: (String) async -> Void
    @State private var saving = false

    var body: some View {
        NavigationStack {
            PaperForm {
                TextField("写下这一刻", text: $caption, axis: .vertical).lineLimit(3 ... 8)
            }
            .paperList()
            .navigationTitle("编辑文案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") {
                        saving = true
                        Task {
                            await onSave(caption.trimmingCharacters(in: .whitespacesAndNewlines))
                            dismiss()
                        }
                    }
                    .disabled(saving)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
