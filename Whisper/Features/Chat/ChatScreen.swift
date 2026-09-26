import SwiftUI

/// SwiftUI 里嵌 UIKit 的聊天页，加上导航栏的标题和菜单
struct ChatScreen: View {
    @Environment(AppModel.self) private var app
    let conversationId: String
    @State private var showSearch = false
    @State private var showCalendar = false
    @State private var showGallery = false
    @State private var showWallpaper = false

    var body: some View {
        ChatControllerView(conversationId: conversationId)
            .ignoresSafeArea(.keyboard)
            // 时间线延伸到导航栏下面、背景铺到屏幕最底下，上下留白由聊天页自己处理
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            .toolbar(.hidden, for: .tabBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ChatHeader(conversationId: conversationId)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("搜索聊天记录", systemImage: "magnifyingglass") { showSearch = true }
                        Button("按日期查找", systemImage: "calendar") { showCalendar = true }
                        Button("照片和视频", systemImage: "photo.on.rectangle") { showGallery = true }
                        Button("聊天背景", systemImage: "photo.artframe") { showWallpaper = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .sheet(isPresented: $showSearch) {
                SearchView(conversationId: conversationId) { messageId in
                    showSearch = false
                    Task { await app.chat(conversationId).jump(to: messageId) }
                }
            }
            .sheet(isPresented: $showCalendar) {
                JumpToDateView(conversationId: conversationId) { day in
                    showCalendar = false
                    Task { await app.chat(conversationId).jump(toDay: day) }
                }
            }
            .sheet(isPresented: $showGallery) {
                NavigationStack { ChatGalleryView(conversationId: conversationId) }
            }
            .sheet(isPresented: $showWallpaper) {
                NavigationStack { ChatWallpaperView() }
            }
            .onAppear { app.focusedConversation = conversationId }
            .onDisappear {
                if app.focusedConversation == conversationId { app.focusedConversation = nil }
            }
    }
}

struct ChatControllerView: UIViewControllerRepresentable {
    @Environment(AppModel.self) private var app
    let conversationId: String

    func makeUIViewController(context: Context) -> ChatViewController {
        ChatViewController(chat: app.chat(conversationId), app: app)
    }

    func updateUIViewController(_ controller: ChatViewController, context: Context) {}
}

/// 标题：头像 + 名字 + 状态（正在输入 / 在线 / 最后在线 / 签名）
struct ChatHeader: View {
    @Environment(AppModel.self) private var app
    let conversationId: String

    var body: some View {
        let isDaju = conversationId.hasPrefix("daju-")
        let userId = isDaju ? "daju" : app.partner?.id
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            HStack(spacing: 10) {
                AvatarView(userId: userId, size: 34)
                    .overlay(alignment: .bottomTrailing) {
                        if !isDaju, let id = userId, app.presence[id]?.online == true {
                            Circle().fill(.green).frame(width: 10, height: 10).overlay(Circle().stroke(.background, lineWidth: 2))
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(isDaju ? (app.daju?.displayName ?? "大橘") : (userId.map { app.name($0) } ?? ""))
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle(isDaju: isDaju, userId: userId))
                        .font(.caption)
                        .foregroundStyle(isActive(isDaju: isDaju) ? Theme.accentColor : Color.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
        }
    }

    private func isActive(isDaju: Bool) -> Bool {
        isDaju ? app.dajuActivity[conversationId] != nil : app.isTyping(conversationId)
    }

    private func subtitle(isDaju: Bool, userId: String?) -> String {
        if isDaju {
            if let activity = app.dajuActivity[conversationId] { return TimelineBuilder.dajuText(activity) + "…" }
            return app.features.daju ? "你的专属大橘" : "大橘暂时不在线"
        }
        if app.isTyping(conversationId) { return "正在输入…" }
        guard let userId else { return "" }
        // 只显示在线状态；自己设的状态（想贴贴这类）在聊天首页看
        let presence = app.presence[userId]
        if presence?.online == true { return "在线" }
        return Format.lastSeen(presence?.lastSeenAt)
    }
}
