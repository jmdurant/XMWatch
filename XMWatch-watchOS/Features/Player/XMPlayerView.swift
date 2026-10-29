import SwiftUI
import WatchKit

struct XMPlayerView: View {
    @Environment(XMRadioService.self) private var radioService

    var body: some View {
        ScrollView {
            XMPlaybackDevicePicker()
            if let channel = radioService.currentChannel {
                VStack(spacing: 10) {
                    // Song title + Artist
                    VStack(spacing: 2) {
                        if radioService.isReconnecting {
                            ProgressView()
                                .padding(.bottom, 2)
                            Text(channel.name)
                                .font(.headline)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            Text("Reconnecting…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if radioService.isBuffering {
                            ProgressView()
                                .padding(.bottom, 2)
                            Text(channel.name)
                                .font(.headline)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            Text("Tuning Ch. \(channel.number)...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(radioService.nowPlayingSong ?? channel.name)
                                .font(.headline)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)

                            Text(radioService.nowPlayingArtist ?? "Ch. \(channel.number)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    // Controls
                    HStack(spacing: 20) {
                        Button {
                            Task { await radioService.previousChannel() }
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)

                        Button {
                            radioService.togglePlayback()
                        } label: {
                            Image(systemName: !radioService.userWantsPlayback ? "play.fill" : "pause.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task { await radioService.nextChannel() }
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "radio")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Channel Selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Choose a channel from the Channels tab")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .navigationTitle("Details")
    }

}

/// Source selection lives on Details, leaving the native player full-screen.
struct XMPlaybackDevicePicker: View {
    @AppStorage("xm_playback_device") private var playbackDevice = "watch"

    var body: some View {
        Picker("Playback device", selection: $playbackDevice) {
            Label("Apple Watch", systemImage: "applewatch").tag("watch")
            Label("iPhone", systemImage: "iphone").tag("phone")
        }
        .accessibilityIdentifier("watch.playbackDevice")
    }
}
