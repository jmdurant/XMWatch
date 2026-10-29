import SwiftUI
import WatchKit

struct XMPlayerView: View {
    @Environment(XMRadioService.self) private var radioService
    var onControlPhone: () -> Void
    var onChooseChannel: () -> Void
    @State private var page = 1

    // NowPlayingView automatically chooses an audio source. Never offer it as
    // the watch player until local playback is active, or Play could hit iPhone.
    private var watchIsPlaying: Bool {
        radioService.playerController != nil && radioService.userWantsPlayback
            && !radioService.isPaused && !radioService.isBuffering
    }

    var body: some View {
        TabView(selection: $page) {
            if watchIsPlaying {
                NowPlayingView()
                    .ignoresSafeArea(.container, edges: .bottom)
                    .accessibilityIdentifier("watch.player.system")
                    .tag(0)
            }
            details.tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: watchIsPlaying && page == 1 ? .automatic : .never))
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle(page == 0 ? "" : "Details")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { page = watchIsPlaying ? 0 : 1 }
        .onChange(of: watchIsPlaying) { _, playing in page = playing ? 0 : 1 }
    }

    private var details: some View {
        ScrollView {
            VStack(spacing: 12) {
                Label("Apple Watch", systemImage: "applewatch")
                    .font(.headline)
                if let channel = radioService.currentChannel {
                    VStack(spacing: 4) {
                        Text(channel.name + " · Ch. " + channel.number)
                            .font(.caption).foregroundStyle(.secondary)
                        Text(radioService.nowPlayingSong ?? channel.name)
                            .font(.headline).multilineTextAlignment(.center).lineLimit(2)
                        if let artist = radioService.nowPlayingArtist {
                            Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    if radioService.isBuffering || radioService.isReconnecting {
                        ProgressView(radioService.isReconnecting ? "Reconnecting on Watch…" : "Tuning on Watch…")
                    }
                    HStack(spacing: 20) {
                        Button {
                            Task { await radioService.previousChannel() }
                        } label: { Image(systemName: "backward.fill") }
                        .accessibilityLabel("Previous channel on Watch")
                        Button { radioService.togglePlayback() } label: {
                            Image(systemName: radioService.userWantsPlayback ? "pause.fill" : "play.fill")
                                .font(.title2)
                        }
                        .accessibilityLabel(radioService.userWantsPlayback ? "Pause Watch" : "Play on Apple Watch")
                        .accessibilityIdentifier("watch.player.toggle")
                        Button {
                            Task { await radioService.nextChannel() }
                        } label: { Image(systemName: "forward.fill") }
                        .accessibilityLabel("Next channel on Watch")
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 6)
                } else {
                    Text("Choose a channel to listen on your Apple Watch.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let error = radioService.errorMessage {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                }
                Button("Choose Channel", systemImage: "radio", action: onChooseChannel)
                    .accessibilityIdentifier("watch.player.channels")
                Button("Control iPhone", systemImage: "iphone", action: onControlPhone)
                    .accessibilityIdentifier("watch.player.phoneControls")
            }
            .padding(.horizontal, 4)
        }
    }
}
