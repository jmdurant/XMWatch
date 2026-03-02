import SwiftUI

struct XMTabView: View {
    @Environment(XMRadioService.self) private var radioService
    @State private var selectedTab = 1  // Start on Channels tab

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                XMPlayerView()
            }
            .tag(0)

            NavigationStack {
                XMChannelsView(selectedTab: $selectedTab)
            }
            .tag(1)

            NavigationStack {
                XMFavoritesView(selectedTab: $selectedTab)
            }
            .tag(2)

            NavigationStack {
                XMSettingsView()
            }
            .tag(3)
        }
        .task {
            if UserDefaults.standard.bool(forKey: "xm_resume_last_channel"),
               UserDefaults.standard.string(forKey: "xm_last_channel") != nil {
                await radioService.resumeLastChannelIfEnabled()
                selectedTab = 0  // Switch to Now Playing tab
            }
        }
    }
}
