import Foundation
import MediaPlayer
import UIKit

@MainActor
final class NowPlayingManager {
    private weak var coordinator: (any PlayerCoordinating)?
    private let commandCenter = MPRemoteCommandCenter.shared()
    private let infoCenter = MPNowPlayingInfoCenter.default()

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
            Task { @MainActor in self?.coordinator?.resume() }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.coordinator?.pause() }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.coordinator?.togglePlayback() }
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

    func updateMetadata(title: String, artist: String, channel: String, artworkURL: URL?) {
        var info = infoCenter.nowPlayingInfo ?? [:]

        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = artist
        info[MPMediaItemPropertyAlbumTitle] = channel
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

        infoCenter.nowPlayingInfo = info

        if let artworkURL, artworkURL != lastArtworkURL {
            lastArtworkURL = artworkURL
            loadArtwork(from: artworkURL)
        }
    }

    private func loadArtwork(from url: URL) {
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let original = UIImage(data: data) else {
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
        removeRemoteCommands()
        infoCenter.nowPlayingInfo = nil
    }
}
