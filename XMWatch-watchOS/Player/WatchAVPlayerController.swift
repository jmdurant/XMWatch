import AVFoundation
import AVKit
import MediaPlayer

func writeDebug(_ msg: String) {
    let path = NSHomeDirectory() + "/tmp/xmwatch-debug.log"
    let line = "\(Date()): \(msg)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

@MainActor
final class WatchAVPlayerController: PlayerCoordinating {
    private(set) var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    var onPropertyChange: ((PlayerProperty, Any?) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onMediaLoaded: (() -> Void)?

    init(options: PlayerOptions) {}

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        session.activate(options: []) { activated, error in
            if let error {
                debugPrint("Audio session activation failed:", error)
            }
        }
    }

    func play(_ url: URL) {
        writeDebug("[WatchAVPlayer] play url=\(url.absoluteString)")
        configureAudioSession()
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        player?.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        setupObservers()
        player?.play()
    }

    func togglePlayback() {
        guard let player else { return }
        if player.rate == 0 {
            player.play()
        } else {
            player.pause()
        }
    }

    func pause() {
        player?.pause()
    }

    func resume() {
        player?.play()
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(by delta: Double) {
        guard let player, let currentItem = player.currentItem else { return }
        let currentTime = CMTimeGetSeconds(player.currentTime())
        let duration = CMTimeGetSeconds(currentItem.duration)
        let newTime = min(max(0, currentTime + delta), duration)
        seek(to: newTime)
    }

    func setPlaybackRate(_ rate: Float) {
        player?.rate = max(0.1, rate)
    }

    func selectAudioTrack(id: Int?) {
        guard let item = player?.currentItem else { return }
        guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else { return }

        if let id, id < group.options.count {
            item.select(group.options[id], in: group)
        }
    }

    func selectSubtitleTrack(id: Int?) {
        guard let item = player?.currentItem else { return }
        guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }

        if let id, id < group.options.count {
            item.select(group.options[id], in: group)
        } else {
            item.select(nil, in: group)
        }
    }

    func trackList() -> [PlayerTrack] {
        guard let item = player?.currentItem else { return [] }
        var tracks: [PlayerTrack] = []
        var trackId = 0

        if let audioGroup = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            let selected = item.currentMediaSelection.selectedMediaOption(in: audioGroup)
            for option in audioGroup.options {
                let locale = option.locale?.identifier
                tracks.append(PlayerTrack(
                    id: trackId,
                    ffIndex: trackId,
                    type: .audio,
                    title: option.displayName,
                    language: locale,
                    codec: nil,
                    isDefault: option == audioGroup.defaultOption,
                    isSelected: option == selected
                ))
                trackId += 1
            }
        }

        if let subtitleGroup = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            let selected = item.currentMediaSelection.selectedMediaOption(in: subtitleGroup)
            for option in subtitleGroup.options {
                let locale = option.locale?.identifier
                tracks.append(PlayerTrack(
                    id: trackId,
                    ffIndex: trackId,
                    type: .subtitle,
                    title: option.displayName,
                    language: locale,
                    codec: nil,
                    isDefault: option == subtitleGroup.defaultOption,
                    isSelected: option == selected
                ))
                trackId += 1
            }
        }

        return tracks
    }

    func destruct() {
        removeObservers()
        player?.pause()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func setupObservers() {
        guard let player else { return }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.onPropertyChange?(.timePos, CMTimeGetSeconds(time))
            }
        }

        statusObservation = player.currentItem?.observe(\.status) { [weak self] item, _ in
            Task { @MainActor in
                writeDebug("[WatchAVPlayer] status=\(item.status.rawValue), error=\(item.error?.localizedDescription ?? "none")")
                switch item.status {
                case .readyToPlay:
                    let duration = CMTimeGetSeconds(item.duration)
                    writeDebug("[WatchAVPlayer] readyToPlay, duration=\(duration)")
                    if duration.isFinite {
                        self?.onPropertyChange?(.duration, duration)
                    }
                    self?.onMediaLoaded?()
                case .failed:
                    writeDebug("[WatchAVPlayer] FAILED: \(item.error?.localizedDescription ?? "unknown")")
                default:
                    break
                }
            }
        }

        rateObservation = player.observe(\.rate) { [weak self] player, _ in
            Task { @MainActor in
                self?.onPropertyChange?(.pause, player.rate == 0)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onPlaybackEnded?()
            }
        }
    }

    private func removeObservers() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        rateObservation?.invalidate()
        rateObservation = nil
        NotificationCenter.default.removeObserver(self)
    }
}
