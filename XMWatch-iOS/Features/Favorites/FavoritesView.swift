import SwiftUI

struct FavoritesView: View {
    @Environment(XMRadioService.self) private var radioService
    @Binding var selectedTab: Int

    @State private var tuningChannelId: String?

    var body: some View {
        Group {
            if favoriteChannels.isEmpty {
                ContentUnavailableView {
                    Label("No Favorites", systemImage: "star")
                } description: {
                    Text("Swipe right on a channel to add it to favorites.")
                }
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
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: channel.mediumImageURL)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "radio")
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 44, height: 44)
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(channel.number)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)

                    Text(channel.name)
                        .font(.body)
                        .fontWeight(.medium)
                }

                if tuningChannelId == channel.id {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Tuning...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let artist = channel.artist, let song = channel.song {
                    Text("\(artist) - \(song)")
                        .font(.caption)
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
        selectedTab = 0
    }
}
