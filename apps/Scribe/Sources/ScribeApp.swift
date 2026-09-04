import SwiftUI

@main
struct ScribeApp: App {
    @State private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView().environment(app)
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 640)
        #endif
        // Fold the write-ahead log back into scribe.sqlite whenever the app
        // stops being used. Without it a recent meeting can live only in the
        // -wal file, and anyone backing up "the database" by copying the one
        // obvious file would quietly leave their newest meetings behind.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { app.store?.checkpoint() }
        }

        #if os(macOS)
        Settings {
            SettingsView().environment(app)
        }
        #endif
    }
}
