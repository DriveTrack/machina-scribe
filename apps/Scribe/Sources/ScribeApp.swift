import SwiftUI

@main
struct ScribeApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView().environment(app)
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 640)
        #endif

        #if os(macOS)
        Settings {
            SettingsView().environment(app)
        }
        #endif
    }
}
