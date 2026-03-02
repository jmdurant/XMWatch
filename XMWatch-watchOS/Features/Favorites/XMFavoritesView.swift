import SwiftUI

struct XMFavoritesView: View {
    @Environment(XMRadioService.self) private var radioService
    @Binding var selectedTab: Int

    @State private var tuningChannelId: String?

    var body: some View {
        Group {
            if favoriteChannels.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "star")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Favorites Yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Star channels from the Channels tab")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                List {
                    ForEach(favoriteChannels) { channel in
                        Button {
                            Task { await tuneChannel(channel) }
                        } label: {
                            channelRow(channel)
                        }
                        .disabled(tuningChannelId != nil)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                radioService.toggleFavorite(channelNumber: channel.number)
                            } label: {
                                Image(systemName: "star.slash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Favorites")
    }

    private var favoriteChannels: [XMChannel] {
        radioService.channels.filter {
            radioService.favoriteChannelNumbers.contains($0.number)
        }
    }

    @ViewBuilder
    private func channelRow(_ channel: XMChannel) -> some View {
        HStack(spacing: 8) {
            Text(channel.number)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.caption)
                    .fontWeight(.medium)

                if tuningChannelId == channel.id {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("Tuning...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if let artist = channel.artist, let song = channel.song {
                    Text("\(artist) - \(song)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func tuneChannel(_ channel: XMChannel) async {
        tuningChannelId = channel.id
        await radioService.startPlayback(channel: channel)
        tuningChannelId = nil
        selectedTab = 0  // Switch to Now Playing tab
    }
}
