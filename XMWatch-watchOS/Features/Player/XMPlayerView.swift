import AVFoundation
import SwiftUI

struct XMPlayerView: View {
    @Environment(XMRadioService.self) private var radioService

    @State private var coordinator: WatchAVPlayerController?
    @State private var nowPlayingManager: WatchNowPlayingManager?
    @State private var proxyServer = XMHLSProxyServer.shared
    @State private var isPaused = true
    @State private var pdtTimer: Task<Void, Never>?
    @State private var tokenTimer: Task<Void, Never>?

    var body: some View {
        Group {
            if let channel = radioService.currentChannel {
                VStack(spacing: 10) {
                    // Channel logo
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

                    // Song title
                    Text(radioService.nowPlayingSong ?? channel.name)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    // Artist
                    Text(radioService.nowPlayingArtist ?? "Ch. \(channel.number)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    // Channel name + number
                    Text("\(channel.name) - Ch. \(channel.number)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    // Controls
                    HStack(spacing: 20) {
                        // Previous channel
                        Button {
                            Task { await previousChannel() }
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)

                        // Play/Pause
                        Button {
                            coordinator?.togglePlayback()
                        } label: {
                            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)

                        // Next channel
                        Button {
                            Task { await nextChannel() }
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
        .navigationTitle("Now Playing")
        .task {
            await setupPlayer()
        }
        .onChange(of: radioService.currentChannel) {
            Task { await setupPlayer() }
        }
        .onDisappear {
            teardown()
        }
    }

    private func setupPlayer() async {
        guard let channel = radioService.currentChannel else { return }

        // Start HLS proxy if not running
        if !proxyServer.isRunning {
            do {
                try await proxyServer.start()
            } catch {
                writeDebug("[XMPlayer] Failed to start proxy: \(error)")
                return
            }
        }

        // Get proxy URL for this channel
        guard let proxyURL = await radioService.tune(channel: channel) else {
            writeDebug("[XMPlayer] Failed to get proxy URL")
            return
        }

        // Tear down existing player
        coordinator?.destruct()
        nowPlayingManager?.invalidate()

        // Create new player
        let playerController = WatchAVPlayerController(options: PlayerOptions())
        coordinator = playerController

        // Set up property callbacks
        playerController.onPropertyChange = { property, value in
            if case .pause = property, let paused = value as? Bool {
                isPaused = paused
                nowPlayingManager?.updatePlaybackState(rate: paused ? 0.0 : 1.0)
            }
        }

        playerController.onPlaybackEnded = {
            writeDebug("[XMPlayer] Playback ended")
        }

        // Set up now playing manager
        let manager = WatchNowPlayingManager(coordinator: playerController)
        nowPlayingManager = manager

        manager.updateMetadata(
            title: radioService.nowPlayingSong ?? channel.name,
            artist: radioService.nowPlayingArtist ?? "",
            channel: "\(channel.name) - Ch. \(channel.number)",
            artworkURL: radioService.nowPlayingArtURL.flatMap { URL(string: $0) }
        )

        manager.onNextChannel = {
            Task { await nextChannel() }
        }
        manager.onPreviousChannel = {
            Task { await previousChannel() }
        }

        // Play
        writeDebug("[XMPlayer] Playing \(proxyURL.absoluteString)")
        playerController.play(proxyURL)
        isPaused = false

        // Start PDT polling
        startPDTPolling()

        // Start token refresh timer
        startTokenRefresh()
    }

    private func startPDTPolling() {
        pdtTimer?.cancel()
        pdtTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12_000_000_000) // 12 seconds
                guard !Task.isCancelled else { break }

                await radioService.updateNowPlaying()

                // Update now playing info on lock screen
                if let channel = radioService.currentChannel {
                    nowPlayingManager?.updateMetadata(
                        title: radioService.nowPlayingSong ?? channel.name,
                        artist: radioService.nowPlayingArtist ?? "",
                        channel: "\(channel.name) - Ch. \(channel.number)",
                        artworkURL: radioService.nowPlayingArtURL.flatMap { URL(string: $0) }
                    )
                }
            }
        }
    }

    private func startTokenRefresh() {
        tokenTimer?.cancel()
        tokenTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 minutes
                guard !Task.isCancelled else { break }
                await radioService.refreshTokenIfNeeded()
            }
        }
    }

    private func nextChannel() async {
        guard let current = radioService.currentChannel else { return }
        let channels = radioService.channels
        guard let idx = channels.firstIndex(where: { $0.id == current.id }) else { return }
        let nextIdx = (idx + 1) % channels.count
        let nextChannel = channels[nextIdx]
        radioService.currentChannel = nextChannel
    }

    private func previousChannel() async {
        guard let current = radioService.currentChannel else { return }
        let channels = radioService.channels
        guard let idx = channels.firstIndex(where: { $0.id == current.id }) else { return }
        let prevIdx = idx > 0 ? idx - 1 : channels.count - 1
        let prevChannel = channels[prevIdx]
        radioService.currentChannel = prevChannel
    }

    private func teardown() {
        pdtTimer?.cancel()
        pdtTimer = nil
        tokenTimer?.cancel()
        tokenTimer = nil
        nowPlayingManager?.invalidate()
        nowPlayingManager = nil
        coordinator?.destruct()
        coordinator = nil
    }
}
