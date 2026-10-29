import SwiftUI
import WatchKit

struct PhonePlayerView: View {
    @State private var page = 0
    @State private var connectivity = PlaybackConnectivity.shared

    var body: some View {
        TabView(selection: $page) {
            NowPlayingView()
                .ignoresSafeArea(.container, edges: .bottom)
                .accessibilityIdentifier("watch.player.system")
                .tag(0)
            NavigationStack { details }
                .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: page == 0 ? .never : .automatic))
        .ignoresSafeArea(.container, edges: .bottom)
        .task { connectivity.refresh() }
    }

    private var details: some View {
        ScrollView {
            VStack(spacing: 8) {
                XMPlaybackDevicePicker()
                Label("Playing on iPhone", systemImage: "iphone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let state = connectivity.phoneState, let channel = state.channelName {
                    Text(state.title ?? channel)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    if let artist = state.artist, !artist.isEmpty {
                        Text(artist).font(.caption).lineLimit(2)
                    }
                    Text(channel + (state.channelNumber.map { " · Ch. \($0)" } ?? ""))
                        .font(.caption2).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Updated \(state.updatedAt, style: .relative) ago")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !connectivity.isReachable {
                        Text("Last received from iPhone")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if state.isReconnecting {
                        Text("Reconnecting on iPhone…").font(.caption2)
                    } else if state.isBuffering {
                        Text("Tuning on iPhone…").font(.caption2)
                    } else if state.isPaused {
                        Text(state.wantsPlayback ? "Interrupted on iPhone" : "Paused on iPhone")
                            .font(.caption2)
                    }
                    HStack(spacing: 24) {
                        Button { connectivity.send(.previous) } label: { Image(systemName: "backward.fill") }
                            .disabled(connectivity.isCommandPending)
                            .accessibilityLabel("Previous channel on iPhone")
                        Button { connectivity.send(state.wantsPlayback ? .pause : .play) } label: {
                            Image(systemName: state.wantsPlayback ? "pause.fill" : "play.fill")
                                .font(.title2)
                        }
                        .accessibilityLabel(state.wantsPlayback ? "Pause iPhone" : "Play on iPhone")
                        Button { connectivity.send(.next) } label: { Image(systemName: "forward.fill") }
                            .disabled(connectivity.isCommandPending)
                            .accessibilityLabel("Next channel on iPhone")
                    }
                    .buttonStyle(.plain)
                    .disabled(!connectivity.isReachable)
                    .padding(.vertical, 8)
                } else {
                    Image(systemName: "iphone").font(.largeTitle)
                    Text(connectivity.phoneState == nil ? "Connect to iPhone" : "No channel selected on iPhone")
                        .multilineTextAlignment(.center)
                    Text("Open XMWatch on your iPhone and choose a channel.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let error = connectivity.errorMessage {
                    Text(error).font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Refresh") { connectivity.refresh() }
                    .disabled(connectivity.isCommandPending)
            }
            .padding(.horizontal)
        }
        .navigationTitle("Details")
    }
}
