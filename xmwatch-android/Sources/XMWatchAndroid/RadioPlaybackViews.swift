import SwiftUI
import XMRadioCore

/// Keeps the current station within reach while browsing or changing settings.
struct RadioPlaybackAccessory: View {
    let model: ViewModel

    var body: some View {
        if let channel = model.currentChannel {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    Button { model.selectedTab = "player" } label: {
                        HStack(spacing: 12) {
                            RadioPlaybackArtwork(url: model.nowPlayingArtwork ?? channel.artworkURL, size: 48)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.nowPlayingTitle ?? channel.name).font(.subheadline).bold().lineLimit(1)
                                if let artist = model.nowPlayingArtist, !artist.isEmpty {
                                    Text(artist).font(.caption).lineLimit(1)
                                }
                                Text("Channel \(channel.number) · \(channel.name)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).accessibilityLabel("Open Now Playing")
                    if model.isBuffering { ProgressView().accessibilityLabel("Connecting") }
                    Button { model.togglePlayback() } label: {
                        Image(systemName: model.userWantsPlayback ? "pause.fill" : "play.fill")
                            .font(.title2).frame(width: 48, height: 48)
                    }.buttonStyle(.borderless)
                        .accessibilityLabel(model.userWantsPlayback ? "Pause" : "Play")
                }.padding(.horizontal, 12).padding(.vertical, 8)
            }.background(Color.primary.opacity(0.05))
        }
    }
}

struct RadioNowPlayingView: View {
    let model: ViewModel

    var body: some View {
        GeometryReader { geometry in
            if let channel = model.currentChannel {
                let landscape = geometry.size.width > geometry.size.height && geometry.size.width >= 500
                let artworkSize = landscape
                    ? min(280, max(96, min(geometry.size.height - 32, geometry.size.width * 0.38)))
                    : min(240, max(96, min(geometry.size.width - 48, geometry.size.height * 0.38)))
                ScrollView {
                    if landscape {
                        HStack(spacing: 24) {
                            RadioPlaybackArtwork(url: model.nowPlayingArtwork ?? channel.artworkURL, size: artworkSize)
                            RadioPlaybackDetails(model: model, channel: channel)
                                .frame(maxWidth: .infinity)
                        }.padding(16).frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    } else {
                        VStack(spacing: 24) {
                            RadioPlaybackArtwork(url: model.nowPlayingArtwork ?? channel.artworkURL, size: artworkSize)
                            RadioPlaybackDetails(model: model, channel: channel)
                        }.padding(16).frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    }
                }
            } else {
                Text("Choose a channel to start listening.").foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct RadioPlaybackArtwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFit() }
            placeholder: { Image(systemName: "list.bullet").font(.system(size: min(size / 3, 80))) }
            .frame(width: size, height: size)
            .background(Color.black.opacity(0.88)).clipShape(RoundedRectangle(cornerRadius: min(size / 8, 12)))
    }
}

struct RadioPlaybackDetails: View {
    let model: ViewModel
    let channel: RadioChannel

    var body: some View {
        VStack(spacing: 12) {
            Text(model.nowPlayingTitle ?? channel.name).font(.title2).bold()
                .lineLimit(3).multilineTextAlignment(.center)
            Text(model.nowPlayingArtist ?? " ").font(.headline)
                .lineLimit(2).multilineTextAlignment(.center)
            Text("Channel \(channel.number) · \(channel.category)")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.isBuffering { ProgressView("Connecting…") }
            RadioPlaybackControls(model: model)
            if let error = model.playbackError {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
    }
}

struct RadioPlaybackControls: View {
    let model: ViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 32) {
                Button { model.changeChannel(-1) } label: {
                    HStack(spacing: 3) {
                        Rectangle().frame(width: 3, height: 24)
                        Image(systemName: "play.fill").rotationEffect(.degrees(180))
                    }.frame(minWidth: 44, minHeight: 48)
                }.accessibilityLabel("Previous Channel")
                Button { model.togglePlayback() } label: {
                    HStack(spacing: 8) {
                        if model.userWantsPlayback {
                            Rectangle().frame(width: 10, height: 40)
                            Rectangle().frame(width: 10, height: 40)
                        } else { Image(systemName: "play.fill").font(.system(size: 48)) }
                    }.frame(width: 64, height: 64)
                }.accessibilityLabel(model.userWantsPlayback ? "Pause" : "Play")
                Button { model.changeChannel(1) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                        Rectangle().frame(width: 3, height: 24)
                    }.frame(minWidth: 44, minHeight: 48)
                }.accessibilityLabel("Next Channel")
            }.font(.title)
            #if os(Android)
            Button("Audio Output") { _ = AudioOutputLink.open() }
                .frame(minHeight: 48)
            #endif
        }
    }
}
