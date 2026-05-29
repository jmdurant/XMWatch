import AVKit
import SwiftUI

struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct PlayerView: View {
    @Environment(XMRadioService.self) private var radioService
    @State private var isCompact = true

    var body: some View {
        Group {
            if let channel = radioService.currentChannel {
                GeometryReader { geo in
                    let compact = geo.size.width < 600
                    Group {
                        if compact {
                            portraitLayout(channel: channel)
                        } else {
                            landscapeLayout(channel: channel)
                        }
                    }
                    .onAppear { isCompact = compact }
                    .onChange(of: compact) { _, val in isCompact = val }
                }
            } else {
                ContentUnavailableView {
                    Label("No Channel Selected", systemImage: "radio")
                } description: {
                    Text("Choose a channel from the Channels tab.")
                }
            }
        }
        .toolbarVisibility(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private func portraitLayout(channel: XMChannel) -> some View {
        VStack(spacing: 24) {
            VStack(spacing: 4) {
                HStack {
                    Spacer()
                    AudioRoutePicker()
                        .frame(width: 44, height: 44)
                }
                channelArtwork(channel: channel, size: 300)
            }
            songInfo(channel: channel)
            playbackControls
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    @ViewBuilder
    private func landscapeLayout(channel: XMChannel) -> some View {
        HStack(spacing: 40) {
            Spacer()
            channelArtwork(channel: channel, size: 280)
            VStack(spacing: 24) {
                HStack {
                    Spacer()
                    AudioRoutePicker()
                        .frame(width: 44, height: 44)
                }
                songInfo(channel: channel)
                playbackControls
            }
            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private func channelArtwork(channel: XMChannel, size: CGFloat) -> some View {
        Group {
            if let artURL = radioService.nowPlayingArtURL, let url = URL(string: artURL) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    channelImage(channel, size: size)
                }
            } else {
                channelImage(channel, size: size)
            }
        }
        .frame(width: size, height: size)
        .cornerRadius(16)
        .shadow(radius: 8)
    }

    @ViewBuilder
    private func channelImage(_ channel: XMChannel, size: CGFloat) -> some View {
        AsyncImage(url: URL(string: channel.largeImageURL)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "radio")
                        .font(.system(size: size * 0.3))
                        .foregroundStyle(.secondary)
                }
        }
    }

    @ViewBuilder
    private func songInfo(channel: XMChannel) -> some View {
        VStack(spacing: 6) {
            if radioService.isReconnecting {
                ProgressView()
                    .padding(.bottom, 4)
                Text(channel.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("Reconnecting…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if radioService.isBuffering {
                ProgressView()
                    .padding(.bottom, 4)
                Text(channel.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("Tuning Ch. \(channel.number)...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(radioService.nowPlayingSong ?? channel.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(radioService.nowPlayingArtist ?? "Ch. \(channel.number)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("\(channel.name) - Ch. \(channel.number)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var playbackControls: some View {
        HStack(spacing: 40) {
            Button {
                Task { await radioService.previousChannel() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
            }

            Button {
                radioService.togglePlayback()
            } label: {
                Image(systemName: radioService.isPaused ? "play.circle.fill" : "pause.circle.fill")
                    .font(.system(size: 56))
            }

            Button {
                Task { await radioService.nextChannel() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .opacity(radioService.isBuffering ? 0.4 : 1.0)
        .disabled(radioService.isBuffering)
    }
}
