import AVFoundation
import AVKit
import MediaPlayer

func writeDebug(_ msg: String) {
    guard UserDefaults.standard.bool(forKey: "xm_debug_mode") else { return }
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
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var likelyToKeepUpObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var stallEscalationTask: Task<Void, Never>?
    /// Seconds a stall must persist (with no self-recovery) before we escalate to a full reconnect.
    private let stallGracePeriod: UInt64 = 8
    var onPropertyChange: ((PlayerProperty, Any?) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onPlaybackFailed: ((Error?) -> Void)?
    var onMediaLoaded: (() -> Void)?
    /// Fired when playback stalls (buffer underrun / network drop) and does not
    /// self-recover within `stallGracePeriod`. The service treats this like a
    /// failure and re-establishes the session.
    var onPlaybackStalled: (() -> Void)?

    init(options: PlayerOptions) {}

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
        session.activate(options: []) { activated, error in
            if let error {
                writeDebug("[WatchAVPlayer] Audio session activation failed: \(error)")
            }
            writeDebug("[WatchAVPlayer] Audio session activated: \(activated)")
        }
    }

    func play(_ url: URL) {
        writeDebug("[WatchAVPlayer] play url=\(url.absoluteString)")
        configureAudioSession()
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        player?.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        player?.automaticallyWaitsToMinimizeStalling = false
        setupObservers()
        player?.play()
        writeDebug("[WatchAVPlayer] player.play() called, rate=\(player?.rate ?? -1), timeControlStatus=\(player?.timeControlStatus.rawValue ?? -1)")
    }

    /// Periodically log player state for debugging
    func logPlayerState() {
        guard let player else {
            writeDebug("[WatchAVPlayer] logState: no player")
            return
        }
        let status = player.currentItem?.status.rawValue ?? -1
        let rate = player.rate
        let tcs = player.timeControlStatus.rawValue
        let err = player.currentItem?.error?.localizedDescription ?? "none"
        let route = AVAudioSession.sharedInstance().currentRoute
        let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
        writeDebug("[WatchAVPlayer] state: itemStatus=\(status) rate=\(rate) timeCtrl=\(tcs) err=\(err) audioRoute=[\(outputs)]")
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

    /// Called when the stream underruns. With `automaticallyWaitsToMinimizeStalling`
    /// off, AVPlayer won't resume on its own, so we nudge it and start a grace
    /// timer. If the buffer refills, `likelyToKeepUpObservation` cancels the timer;
    /// if it doesn't, we escalate to a full reconnect.
    private func handleStall() {
        guard player != nil else { return }
        writeDebug("[WatchAVPlayer] stall detected, nudging playback")
        player?.play()
        guard stallEscalationTask == nil else { return }
        stallEscalationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: (self?.stallGracePeriod ?? 8) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.stallEscalationTask = nil
            let likely = self.player?.currentItem?.isPlaybackLikelyToKeepUp ?? false
            let rate = self.player?.rate ?? 0
            if !likely && rate == 0 {
                writeDebug("[WatchAVPlayer] stall persisted, escalating to reconnect")
                self.onPlaybackStalled?()
            }
        }
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
                    // Resume playback if player stalled waiting for data
                    if self?.player?.rate == 0 {
                        writeDebug("[WatchAVPlayer] resuming playback after readyToPlay")
                        self?.player?.play()
                    }
                    self?.onMediaLoaded?()
                case .failed:
                    writeDebug("[WatchAVPlayer] FAILED: \(item.error?.localizedDescription ?? "unknown")")
                    self?.onPlaybackFailed?(item.error)
                default:
                    break
                }
            }
        }

        rateObservation = player.observe(\.rate) { [weak self] player, _ in
            Task { @MainActor in
                writeDebug("[WatchAVPlayer] rate changed to \(player.rate)")
                self?.onPropertyChange?(.pause, player.rate == 0)
            }
        }

        // Buffer underrun → potential stall.
        bufferEmptyObservation = player.currentItem?.observe(\.isPlaybackBufferEmpty) { [weak self] item, _ in
            guard item.isPlaybackBufferEmpty else { return }
            Task { @MainActor in self?.handleStall() }
        }

        // Buffer refilled → cancel any pending escalation and resume if stopped.
        likelyToKeepUpObservation = player.currentItem?.observe(\.isPlaybackLikelyToKeepUp) { [weak self] item, _ in
            guard item.isPlaybackLikelyToKeepUp else { return }
            Task { @MainActor in
                guard let self else { return }
                self.stallEscalationTask?.cancel()
                self.stallEscalationTask = nil
                if self.player?.rate == 0 {
                    writeDebug("[WatchAVPlayer] buffer recovered, resuming")
                    self.player?.play()
                }
            }
        }

        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleStall() }
        })

        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onPlaybackEnded?()
            }
        })
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
        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = nil
        likelyToKeepUpObservation?.invalidate()
        likelyToKeepUpObservation = nil
        stallEscalationTask?.cancel()
        stallEscalationTask = nil
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
    }
}
