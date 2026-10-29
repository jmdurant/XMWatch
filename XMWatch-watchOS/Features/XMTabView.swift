import SwiftUI

private enum XMWatchRoute: Hashable {
    case channels, favorites, settings, watchPlayer, phonePlayer, signIn
}

/// Separate destinations make choosing a playback device explicit. A saved phone
/// preference never drops the user into generic system playback controls at launch.
struct XMTabView: View {
    @Environment(XMRadioService.self) private var radioService
    @State private var path: [XMWatchRoute] = []
    @State private var connectivity = PlaybackConnectivity.shared

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Apple Watch") {
                    if radioService.currentChannel != nil {
                        NavigationLink(value: XMWatchRoute.watchPlayer) {
                            Label("Watch Player", systemImage: "applewatch")
                        }
                        .accessibilityIdentifier("watch.nowPlaying")
                    }
                    if radioService.status == .ready {
                        NavigationLink(value: XMWatchRoute.channels) {
                            Label("Play on Apple Watch", systemImage: "radio")
                        }
                        .accessibilityIdentifier("watch.channels")
                        NavigationLink(value: XMWatchRoute.favorites) {
                            Label("Favorites", systemImage: "star")
                        }
                        NavigationLink(value: XMWatchRoute.settings) {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } else {
                        NavigationLink(value: XMWatchRoute.signIn) {
                            Label("Sign In on Watch", systemImage: "person.crop.circle")
                        }
                    }
                }
                Section("iPhone") {
                    NavigationLink(value: XMWatchRoute.phonePlayer) {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Control iPhone", systemImage: "iphone")
                            if let state = connectivity.phoneState, let channel = state.channelName {
                                Text(state.title ?? channel)
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .accessibilityIdentifier("watch.phone.nowPlaying")
                }
            }
            .navigationTitle("XMWatch")
            .navigationDestination(for: XMWatchRoute.self) { route in
                switch route {
                case .channels:
                    if radioService.status == .ready {
                        XMChannelsView(onPlay: showWatchPlayer)
                    } else if radioService.isConfigured {
                        XMSignInView()
                    } else { ProgressView("Loading…") }
                case .favorites:
                    XMFavoritesView(onPlay: showWatchPlayer)
                case .settings:
                    XMSettingsView()
                case .watchPlayer:
                    XMPlayerView(onControlPhone: { path.append(.phonePlayer) },
                                 onChooseChannel: { path.append(.channels) })
                case .phonePlayer:
                    PhonePlayerView(onWatchPlayer: showWatchPlayer)
                case .signIn:
                    if radioService.isConfigured { XMSignInView() }
                    else { ProgressView("Loading…") }
                }
            }
        }
        .task(id: radioService.status) {
            connectivity.refresh()
            await radioService.resumeOnceAfterConfiguration()
        }
        .onChange(of: radioService.status) { _, status in
            if status == .ready, path.last == .signIn { path.removeLast() }
        }
        .onChange(of: path.last) { _, route in
            switch route {
            case .phonePlayer:
                UserDefaults.standard.set("phone", forKey: "xm_playback_device")
                radioService.stopForPhoneMode()
                connectivity.refresh()
            case .watchPlayer, .channels, .favorites:
                UserDefaults.standard.set("watch", forKey: "xm_playback_device")
            default: break
            }
        }
    }

    private func showWatchPlayer() {
        UserDefaults.standard.set("watch", forKey: "xm_playback_device")
        if path.last == .phonePlayer { path.removeLast() }
        if path.last != .watchPlayer { path.append(.watchPlayer) }
    }
}
