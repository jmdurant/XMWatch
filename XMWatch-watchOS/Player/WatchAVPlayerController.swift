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
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var likelyToKeepUpObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var stallEscalationTask: Task<Void, Never>?
    private var audioSelectionGroup: AVMediaSelectionGroup?
    private var subtitleSelectionGroup: AVMediaSelectionGroup?
    /// How long a stall must persist (with no self-recovery) before we escalate to a full reconnect.
    private let stallGracePeriod = Duration.seconds(8)
    /// The user's intent, not the player's rate — rate reads 0 while stalled as well,
    /// and mistaking that for a pause (or the reverse) makes the player resume itself.
    private var isPausedByUser = false
    private var isBuffering = false
    private var shouldResumeAfterInterruption = false
    private(set) var isSuspended = false
    private var audioSessionReady = false
    private var activationGeneration = UUID()
    var onPauseRequested: (() -> Void)?
    var onPropertyChange: ((PlayerProperty, Any?) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onPlaybackFailed: ((Error?) -> Void)?
    var onMediaLoaded: (() -> Void)?
    /// Fired when playback stalls (buffer underrun / network drop) and does not
    /// self-recover within `stallGracePeriod`. The service treats this like a
    /// failure and re-establishes the session.
    var onPlaybackStalled: (() -> Void)?

    var isPaused: Bool { isPausedByUser }

    init(options: PlayerOptions) {}

    private func configureAudioSession() {
        let generation = UUID()
        activationGeneration = generation
        audioSessionReady = false
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            onPlaybackFailed?(error)
            return
        }
        session.activate(options: []) { [weak self] activated, error in
            Task { @MainActor in
                guard let self, generation == self.activationGeneration,
                      !self.isPausedByUser, !self.isSuspended, self.player != nil else { return }
                guard activated, error == nil else {
                    self.onPlaybackFailed?(error)
                    return
                }
                self.audioSessionReady = true
                self.player?.play()
            }
        }
    }

    func play(_ url: URL) {
        writeDebug("[WatchAVPlayer] play url=\(url.absoluteString)")
        isPausedByUser = false
        isSuspended = false
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        audioSelectionGroup = nil
        subtitleSelectionGroup = nil
        player = AVPlayer(playerItem: item)
        player?.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        player?.automaticallyWaitsToMinimizeStalling = false
        setupObservers()
        configureAudioSession()
        writeDebug("[WatchAVPlayer] playback requested, rate=\(player?.rate ?? -1), timeControlStatus=\(player?.timeControlStatus.rawValue ?? -1)")
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
        // iOS pauses the player itself on a route loss or interruption without routing
        // through pause(), so `isPausedByUser` can read "playing" while the player sits at
        // rate 0. Treat a stopped-and-not-buffering player as paused too, or the next
        // toggle would re-pause an already paused player (the play button doing nothing).
        let effectivelyPaused = isPausedByUser || (player.rate == 0 && !isBuffering)
        if effectivelyPaused {
            resume()
        } else {
            pause()
        }
    }

    func pause() {
        activationGeneration = UUID()
        shouldResumeAfterInterruption = false
        isPausedByUser = true
        // A stall stops mattering once the user pauses: drop the pending escalation so
        // recovery can't reconnect and resume playback behind their back.
        stallEscalationTask?.cancel()
        stallEscalationTask = nil
        setBuffering(false)
        player?.pause()
    }

    func resume() {
        isPausedByUser = false
        isSuspended = false
        configureAudioSession()
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(by delta: Double) {
        guard let player, let currentItem = player.currentItem else { return }
        let duration = CMTimeGetSeconds(currentItem.duration)
        // Live streams report an indefinite duration; clamping against NaN yields NaN,
        // and seeking to an invalid time traps.
        guard duration.isFinite else { return }
        let currentTime = CMTimeGetSeconds(player.currentTime())
        let newTime = min(max(0, currentTime + delta), duration)
        seek(to: newTime)
    }

    func setPlaybackRate(_ rate: Float) {
        player?.rate = max(0.1, rate)
    }

    func selectAudioTrack(id: Int?) {
        guard let item = player?.currentItem else { return }
        guard let group = audioSelectionGroup else { return }

        if let id, id < group.options.count {
            item.select(group.options[id], in: group)
        }
    }

    /// `trackList()` numbers subtitle tracks continuing on from the audio ones, so an id
    /// coming back in has to be rebased onto the legible group's own indices. Anything
    /// outside that range means "no subtitles".
    func selectSubtitleTrack(id: Int?) {
        guard let item = player?.currentItem else { return }
        guard let group = subtitleSelectionGroup else { return }

        if let id {
            let index = id - audioOptionCount
            if index >= 0, index < group.options.count {
                item.select(group.options[index], in: group)
                return
            }
        }
        item.select(nil, in: group)
    }

    /// How many ids `trackList()` consumes before it starts numbering subtitles.
    private var audioOptionCount: Int {
        audioSelectionGroup?.options.count ?? 0
    }

    func trackList() -> [PlayerTrack] {
        guard let item = player?.currentItem else { return [] }
        var tracks: [PlayerTrack] = []
        var trackId = 0

        if let audioGroup = audioSelectionGroup {
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

        if let subtitleGroup = subtitleSelectionGroup {
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
        activationGeneration = UUID()
        isPausedByUser = true
        audioSessionReady = false
        onPropertyChange = nil
        onPlaybackEnded = nil
        onPlaybackFailed = nil
        onPlaybackStalled = nil
        onMediaLoaded = nil
        onPauseRequested = nil
        removeObservers()
        player?.pause()
        player = nil
        audioSelectionGroup = nil
        subtitleSelectionGroup = nil
        shouldResumeAfterInterruption = false
        isBuffering = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// Single owner of the buffering flag, so a healthy stream doesn't republish it on
    /// every keep-up toggle and no exit path can leave the UI stuck on a spinner.
    private func setBuffering(_ buffering: Bool) {
        guard isBuffering != buffering else { return }
        isBuffering = buffering
        onPropertyChange?(.pausedForCache, buffering)
        // Entering a stall retracts the `paused` we published when the rate hit 0.
        // Leaving one needs no publish: the rate observer fires as playback resumes.
        if buffering {
            publishPauseState()
        }
    }

    /// A stalled player reports rate 0, which is not a pause. Only report `paused` when
    /// playback is stopped for some reason other than waiting on data — a real pause,
    /// or an external interruption such as a phone call.
    private func publishPauseState() {
        onPropertyChange?(.pause, (player?.rate ?? 0) == 0 && !isBuffering)
    }

    /// Called when the stream underruns. With `automaticallyWaitsToMinimizeStalling`
    /// off, AVPlayer won't resume on its own, so we nudge it and start a grace
    /// timer. If playback makes forward progress the escalation is cancelled;
    /// if it doesn't, we escalate to a full reconnect.
    private func handleStall() {
        guard let player, !isPausedByUser, !isSuspended, audioSessionReady else { return }
        writeDebug("[WatchAVPlayer] stall detected, nudging playback")
        setBuffering(true)
        player.play()
        guard stallEscalationTask == nil else { return }

        let stalledAt = CMTimeGetSeconds(player.currentTime())
        let startPosition = stalledAt.isFinite ? stalledAt : 0
        let grace = stallGracePeriod
        stallEscalationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, !Task.isCancelled else { return }
            // Clear the slot before any other exit, or a later stall can never re-arm.
            self.stallEscalationTask = nil
            guard !self.isPausedByUser, !self.isSuspended else { return }
            // `rate` is a useless signal here: with automaticallyWaitsToMinimizeStalling
            // off, AVPlayer leaves it at 1 on a dead stream, and the nudge above sets it
            // to 1 regardless. Only the clock moving forward proves the stream recovered.
            let now = self.player.map { CMTimeGetSeconds($0.currentTime()) } ?? startPosition
            let progressed = now.isFinite && now > startPosition + 0.5
            if !progressed {
                writeDebug("[WatchAVPlayer] stall persisted (no forward progress), escalating to reconnect")
                self.onPlaybackStalled?()
            }
        }
    }

    private func loadSelectionGroups(for item: AVPlayerItem) async {
        audioSelectionGroup = try? await item.asset.loadMediaSelectionGroup(for: .audible)
        subtitleSelectionGroup = try? await item.asset.loadMediaSelectionGroup(for: .legible)
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
                    await self?.loadSelectionGroups(for: item)
                    let duration = CMTimeGetSeconds(item.duration)
                    writeDebug("[WatchAVPlayer] readyToPlay, duration=\(duration)")
                    if duration.isFinite {
                        self?.onPropertyChange?(.duration, duration)
                    }
                    // Resume playback if the player stalled waiting for data — but never
                    // override a pause the user asked for while the item was loading.
                    if self?.player?.rate == 0, self?.isPausedByUser == false, self?.audioSessionReady == true, self?.isSuspended == false {
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
                self?.publishPauseState()
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
                self.setBuffering(false)
                // Only resume a player the user didn't deliberately pause: pausing during
                // a stall is exactly when this fires, and it must not undo the pause.
                if self.player?.rate == 0, !self.isPausedByUser, self.audioSessionReady, !self.isSuspended {
                    writeDebug("[WatchAVPlayer] buffer recovered, resuming")
                    self.player?.play()
                }
            }
        }

        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleStall() }
        })

        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onPlaybackEnded?()
            }
        })

        let audioSession = AVAudioSession.sharedInstance()
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.didBecomeInactiveNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isSuspended = true
                self.audioSessionReady = false
                self.activationGeneration = UUID()
                self.stallEscalationTask?.cancel()
                self.stallEscalationTask = nil
                self.setBuffering(false)
                self.shouldResumeAfterInterruption =
                    self.player != nil && !self.isPausedByUser
                if self.shouldResumeAfterInterruption {
                    self.player?.pause()
                    self.publishPauseState()
                }
            }
        })

        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.resumptionRecommendationNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            let recommendation =
                (notification.userInfo?[AVAudioSession.resumptionContextKey]
                    as? AVAudioSession.ResumptionContext)?.recommendation
            Task { @MainActor in
                guard let self else { return }
                if self.shouldResumeAfterInterruption,
                   recommendation == .shouldResume,
                   !self.isPausedByUser {
                    self.isSuspended = false
                    self.configureAudioSession()
                } else if self.shouldResumeAfterInterruption {
                    self.onPauseRequested?()
                }
                self.shouldResumeAfterInterruption = false
            }
        })

        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason ?? 0)
            Task { @MainActor in
                guard let self, self.player != nil else { return }
                if reason == .oldDeviceUnavailable {
                    // Route loss is a real pause; recovery must respect it too.
                    self.pause()
                    self.onPauseRequested?()
                }
            }
        })

        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player != nil else { return }
                guard !self.isPausedByUser, !self.isSuspended else { return }
                self.onPlaybackStalled?()
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
