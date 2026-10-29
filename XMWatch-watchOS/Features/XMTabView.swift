import SwiftUI
import WatchKit

struct XMTabView: View {
    @Environment(XMRadioService.self) private var radioService
    @State private var selectedTab = 1  // Start on Channels tab

    var body: some View {
        TabView(selection: $selectedTab) {
            NowPlayingView()
                .accessibilityIdentifier("watch.player.system")
                .tag(0)

            NavigationStack {
                XMPlayerView()
            }
            .tag(4)

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
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .task(id: radioService.isConfigured) {
            await radioService.resumeOnceAfterConfiguration()
            if radioService.currentChannel != nil { selectedTab = 0 }
        }
    }
}
