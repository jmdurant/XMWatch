import Foundation
import MediaPlayer
import UIKit

@MainActor
final class NowPlayingManager {
    private weak var coordinator: (any PlayerCoordinating)?
    private let commandCenter = MPRemoteCommandCenter.shared()
    private let infoCenter = MPNowPlayingInfoCenter.default()

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    private var artworkTask: Task<Void, Never>?
    private var artworkGeneration = UUID()
    var onTogglePlayback: (() -> Void)?
    var onNextChannel: (() -> Void)?
    var onPreviousChannel: (() -> Void)?
    private var lastArtworkURL: URL?

    init(coordinator: any PlayerCoordinating) {
        self.coordinator = coordinator
        setupRemoteCommands()
    }

    // MARK: - Remote Commands

    private func setupRemoteCommands() {
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPlay?() }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPause?() }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onTogglePlayback?() }
            return .success
        }

        // No seek for live radio
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false

        // Next/Previous channel
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onNextChannel?() }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPreviousChannel?() }
            return .success
        }
    }

    private func removeRemoteCommands() {
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
    }

    // MARK: - XM Metadata

    func updateMetadata(title: String, artist: String, channel: XMChannel, artworkURL: URL?) {
        var info = infoCenter.nowPlayingInfo ?? [:]

        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = artist
        info[MPMediaItemPropertyAlbumTitle] = "\(channel.name) - Ch. \(channel.number)"
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        if let appEntityIdentifier =
            XMRadioEntityDonations.nowPlayingIdentifier(for: channel) {
            info[MPNowPlayingInfoPropertyAppEntityIdentifiers] = [
                appEntityIdentifier
            ]
        }

        infoCenter.nowPlayingInfo = info
        XMRadioEntityDonations.update(with: channel)

        if artworkURL != lastArtworkURL {
            artworkTask?.cancel()
            artworkTask = nil
            artworkGeneration = UUID()
            lastArtworkURL = artworkURL
            var cleared = infoCenter.nowPlayingInfo ?? [:]
            cleared.removeValue(forKey: MPMediaItemPropertyArtwork)
            infoCenter.nowPlayingInfo = cleared
        }
        if let artworkURL, artworkTask == nil,
           infoCenter.nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil {
            loadArtwork(from: artworkURL)
        }
    }

    private func loadArtwork(from url: URL) {
        guard !UIApplication.shared.systemPrefersReducedResourceUsage else { return }
        let generation = artworkGeneration
        artworkTask = Task {
            defer { if generation == self.artworkGeneration { self.artworkTask = nil } }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let original = UIImage(data: data),
                  !Task.isCancelled, generation == self.artworkGeneration,
                  self.lastArtworkURL == url else {
                return
            }

            // Composite onto a dark background so white/transparent logos are visible
            let size = original.size
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { ctx in
                UIColor(white: 0.15, alpha: 1).setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                original.draw(in: CGRect(origin: .zero, size: size))
            }

            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var info = self.infoCenter.nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            self.infoCenter.nowPlayingInfo = info
        }
    }

    // MARK: - Playback State

    func updatePlaybackState(rate: Double) {
        var info = infoCenter.nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        infoCenter.nowPlayingInfo = info
    }

    // MARK: - Teardown

    func invalidate() {
        artworkGeneration = UUID()
        artworkTask?.cancel()
        artworkTask = nil
        lastArtworkURL = nil
        removeRemoteCommands()
        infoCenter.nowPlayingInfo = nil
    }
}
