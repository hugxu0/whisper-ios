import SwiftUI

@main
struct WhisperApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("theme") private var theme = "tangerine"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Theme.accentColor)
                .id(theme)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .onOpenURL { app.handleDeepLink($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: app.sceneBecameActive()
            case .background: app.sceneEnteredBackground()
            default: break
            }
        }
    }
}
