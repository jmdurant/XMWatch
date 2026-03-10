import SwiftUI

struct MainTabView: View {
    @Environment(XMRadioService.self) private var radioService
    @State private var selectedTab = 1  // Start on Channels tab

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Now Playing", systemImage: "play.circle", value: 0) {
                NavigationStack {
                    PlayerView()
                }
            }

            Tab("Channels", systemImage: "radio", value: 1) {
                NavigationStack {
                    ChannelsView(selectedTab: $selectedTab)
                }
            }

            Tab("Favorites", systemImage: "star", value: 2) {
                NavigationStack {
                    FavoritesView(selectedTab: $selectedTab)
                }
            }

            Tab("Settings", systemImage: "gear", value: 3) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .task {
            if UserDefaults.standard.bool(forKey: "xm_resume_last_channel"),
               UserDefaults.standard.string(forKey: "xm_last_channel") != nil {
                await radioService.resumeLastChannelIfEnabled()
                selectedTab = 0
            }
        }
    }
}
