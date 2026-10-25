import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some View {
        Group {
            if onboardingComplete {
                MainTabView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: onboardingComplete)
        .tint(Theme.ink)
    }
}

struct MainTabView: View {
    @Environment(AppState.self) private var app
    @State private var showSettings = false
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            Tab("Closet", systemImage: "hanger", value: 0) {
                NavigationStack { ClosetView().toolbar { settingsButton } }
            }
            Tab("Style", systemImage: "sparkles", value: 1) {
                NavigationStack { StyleView().toolbar { settingsButton } }
            }
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right", value: 2) {
                NavigationStack { ChatView().toolbar { settingsButton } }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task { await app.refreshAll() }
    }

    private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
    }
}

#Preview {
    ContentView().environment(AppState())
}
