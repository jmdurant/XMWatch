import SwiftUI

struct XMTabView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                XMPlayerView()
            }
            .tag(0)

            NavigationStack {
                XMChannelsView()
            }
            .tag(1)

            NavigationStack {
                XMFavoritesView()
            }
            .tag(2)

            NavigationStack {
                XMSettingsView()
            }
            .tag(3)
        }
    }
}
