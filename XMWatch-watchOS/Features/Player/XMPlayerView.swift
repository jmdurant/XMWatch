import SwiftUI

struct XMPlayerView: View {
    @Environment(XMRadioService.self) private var radioService

    var body: some View {
        Group {
            if let channel = radioService.currentChannel {
                VStack(spacing: 10) {
                    // Album art or channel logo
                    if let artURL = radioService.nowPlayingArtURL, let url = URL(string: artURL) {
                        AsyncImage(url: url) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } placeholder: {
                            channelImage(channel)
                        }
                        .frame(width: 80, height: 80)
                        .cornerRadius(8)
                    } else {
                        channelImage(channel)
                    }

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
                            Image(systemName: radioService.isPaused ? "play.fill" : "pause.fill")
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
                    .opacity(radioService.isBuffering ? 0.4 : 1.0)
                    .disabled(radioService.isBuffering)
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
        .navigationTitle("Now Playing")
    }

    @ViewBuilder
    private func channelImage(_ channel: XMChannel) -> some View {
        AsyncImage(url: URL(string: channel.mediumImageURL)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "radio")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: 80, height: 80)
        .cornerRadius(8)
    }
}
