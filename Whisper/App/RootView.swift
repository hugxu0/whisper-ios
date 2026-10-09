import SwiftUI

enum AppTab: Hashable {
    case chat, us, daju, me
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var splashDone = false

    var body: some View {
        ZStack {
            switch app.phase {
            case .launching, .syncing:
                LaunchSplashView()
            case .loggedOut:
                LoginView()
                    .onAppear { app.autoLoginIfRequested() }
            case .ready:
                MainTabView()
            }
            if !splashDone {
                LaunchSplashView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .task {
            // 每次启动开屏停留一小会儿；自动化截图时跳过
            if UserDefaults.standard.string(forKey: "autologin") != nil {
                splashDone = true
                return
            }
            try? await Task.sleep(for: .seconds(1.1))
            withAnimation(.easeOut(duration: 0.35)) { splashDone = true }
        }
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: AppTab = .chat

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $selection) {
                // 聊天标签只算情侣聊天的未读；和大橘私聊的未读显示在大橘标签上，不会误以为是对方发的
                Tab("聊天", systemImage: "bubble.left.and.bubble.right.fill", value: .chat) {
                    ChatTab()
                }
                .badge(app.coupleUnread)

                Tab("我们", systemImage: "heart.fill", value: .us) {
                    UsView()
                }
                .badge(app.albumUnread)

                Tab("大橘", systemImage: "pawprint.fill", value: .daju) {
                    DajuView()
                }
                .badge(app.dajuUnread)

                // 签名两天内到期：“我”上标个点，提醒去续签
                Tab("我", systemImage: "person.crop.circle.fill", value: .me) {
                    MeView()
                }
                .badge(Signing.expiringSoon() ? Text("!") : nil)
            }
            .tabBarMinimizeBehavior(.onScrollDown)

            if let banner = app.banner {
                BannerView(banner: banner) {
                    app.banner = nil
                    selection = .chat
                    app.openConversationRequest = banner.conversationId
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }

            InteractionEffectLayer()
                .allowsHitTesting(false)
        }
        .animation(.spring(duration: 0.4), value: app.banner)
        .onChange(of: app.openConversationRequest) { _, request in
            if request != nil { selection = .chat }
        }
        .onAppear(perform: applyTabRequest)
        .onChange(of: app.tabRequest) { applyTabRequest() }
    }

    private func applyTabRequest() {
        guard let request = app.tabRequest else { return }
        switch request {
        case "us": selection = .us
        case "daju": selection = .daju
        case "me": selection = .me
        default: selection = .chat
        }
        app.tabRequest = nil
    }
}

/// 应用内的新消息横幅
struct BannerView: View {
    @Environment(AppModel.self) private var app
    let banner: Banner
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                AvatarView(userId: banner.senderId, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title).font(.subheadline.weight(.semibold))
                    Text(banner.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .gesture(DragGesture(minimumDistance: 10).onEnded { value in
            if value.translation.height < -10 { app.banner = nil }
        })
    }
}
