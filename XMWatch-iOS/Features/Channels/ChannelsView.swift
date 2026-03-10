import SwiftUI

struct ChannelsView: View {
    @Environment(XMRadioService.self) private var radioService
    @Binding var selectedTab: Int

    @State private var searchText = ""
    @State private var selectedCategory = "All"
    @State private var tuningChannelId: String?

    var body: some View {
        Group {
            if radioService.channels.isEmpty {
                ProgressView("Loading channels...")
            } else {
                List {
                    // Category picker
                    Picker("Category", selection: $selectedCategory) {
                        Text("All").tag("All")
                        ForEach(radioService.categories, id: \.self) { category in
                            Text(category).tag(category)
                        }
                    }

                    ForEach(filteredChannels) { channel in
                        Button {
                            Task { await tuneChannel(channel) }
                        } label: {
                            channelRow(channel)
                        }
                        .disabled(tuningChannelId != nil)
                        .swipeActions(edge: .trailing) {
                            Button {
                                radioService.toggleFavorite(channelNumber: channel.number)
                            } label: {
                                Image(systemName: radioService.favoriteChannelNumbers.contains(channel.number) ? "star.slash" : "star")
                            }
                            .tint(.yellow)
                        }
                    }
                }
                .searchable(text: $searchText, prompt: "Search channels")
            }
        }
        .navigationTitle("Channels")
        .task {
            if radioService.channels.isEmpty {
                await radioService.loadChannels()
            }
            await radioService.updatePDTCache()
        }
        .refreshable {
            await radioService.loadChannels()
            await radioService.updatePDTCache()
        }
    }

    private var filteredChannels: [XMChannel] {
        var result = radioService.channels

        if selectedCategory != "All" {
            result = result.filter { $0.category == selectedCategory }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(query) ||
                $0.number.contains(query) ||
                ($0.artist?.lowercased().contains(query) ?? false)
            }
        }

        return result
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

                    if radioService.favoriteChannelNumbers.contains(channel.number) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
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
        selectedTab = 0  // Switch to Now Playing tab
    }
}
