import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if !app.isConfigured || !app.signedIn {
                SettingsView(isOnboarding: true)
            } else {
                MainTabs()
            }
        }
        .task { await app.refreshSession() }
    }
}

private struct MainTabs: View {
    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            MeetingsView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            NavigationStack { RecordView() }
        }
        #else
        TabView {
            NavigationStack { RecordView() }
                .tabItem { Label("Record", systemImage: "mic.circle.fill") }
            NavigationStack { MeetingsView() }
                .tabItem { Label("Meetings", systemImage: "list.bullet.rectangle") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        #endif
    }
}
