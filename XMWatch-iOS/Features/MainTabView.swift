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
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: radioService.currentChannel != nil) {
            XMPlaybackAccessory {
                selectedTab = 0
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

private struct XMPlaybackAccessory: View {
    @Environment(XMRadioService.self) private var radioService
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let onOpen: () -> Void

    private var title: String {
        radioService.nowPlayingSong
            ?? radioService.currentChannel?.name
            ?? "Now Playing"
    }

    var body: some View {
        HStack(spacing: placement == .inline ? 8 : 12) {
            Button(action: onOpen) {
                HStack(spacing: placement == .inline ? 8 : 12) {
                    Image(systemName: "radio.fill")
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(placement == .inline ? .caption : .subheadline)
                            .lineLimit(1)

                        if placement != .inline,
                           let channel = radioService.currentChannel {
                            Text("\(channel.name) · Ch. \(channel.number)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                radioService.togglePlayback()
            } label: {
                Image(systemName: radioService.isPaused ? "play.fill" : "pause.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(radioService.isPaused ? "Play" : "Pause")
        }
        .padding(.horizontal, placement == .inline ? 8 : 12)
        .padding(.vertical, placement == .inline ? 3 : 6)
    }
}
