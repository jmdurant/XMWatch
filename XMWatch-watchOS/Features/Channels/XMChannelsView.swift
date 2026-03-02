import SwiftUI

struct XMChannelsView: View {
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
        HStack(spacing: 8) {
            Text(channel.number)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(channel.name)
                        .font(.caption)
                        .fontWeight(.medium)

                    if radioService.favoriteChannelNumbers.contains(channel.number) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                    }
                }

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
