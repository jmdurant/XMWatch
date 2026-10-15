import Foundation
import Observation
import WatchConnectivity

@MainActor @Observable
final class PlaybackConnectivity: NSObject, WCSessionDelegate {
    static let shared = PlaybackConnectivity()
    private var inbox = PhonePlaybackInbox()
    var phoneState: PhonePlaybackState? { inbox.state }
    private(set) var isReachable = false
    private(set) var isCommandPending = false
    private(set) var errorMessage: String?
    private var session: WCSession?
    private var started = false
    private var commandID: UUID?
    private var timeoutTask: Task<Void, Never>?
    private var service: XMRadioService?
    private var phoneCommandInProgress = false
    private var lastPublishedState: PhonePlaybackState?

    func start(service: XMRadioService) {
        guard !started, WCSession.isSupported() else { return }
        started = true
        self.service = service
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
        #if os(iOS)
        observePlayback()
        #endif
    }

    #if os(iOS)
    private func snapshot() -> PhonePlaybackState {
        guard let service else { return PhonePlaybackState() }
        let channel = service.currentChannel
        return PhonePlaybackState(channelID: channel?.id, channelName: channel?.name,
            channelNumber: channel?.number, title: service.nowPlayingSong,
            artist: service.nowPlayingArtist,
            artworkURL: service.nowPlayingArtURL ?? channel?.largeImageURL,
            wantsPlayback: service.userWantsPlayback, isPaused: service.isPaused,
            isBuffering: service.isBuffering, isReconnecting: service.isReconnecting)
    }

    private func observePlayback() {
        let state = withObservationTracking {
            snapshot()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePlayback() }
        }
        publish(state, onlyIfChanged: true)
    }

    private func publish(_ state: PhonePlaybackState, onlyIfChanged: Bool = false) {
        if onlyIfChanged, let previous = lastPublishedState {
            var comparable = state
            comparable.updatedAt = previous.updatedAt
            if comparable == previous { return }
        }
        guard let session, session.activationState == .activated, session.isWatchAppInstalled else { return }
        do {
            try session.updateApplicationContext(state.payload)
            lastPublishedState = state
        }
        catch { errorMessage = "Could not sync playback to Apple Watch." }
        if session.isReachable {
            session.sendMessage(state.payload, replyHandler: nil, errorHandler: { _ in })
        }
    }
    #endif

    func refresh() {
        #if os(watchOS)
        send(.refresh)
        #else
        publish(snapshot())
        #endif
    }

    func send(_ command: PhonePlaybackCommand) {
        guard !isCommandPending || command == .pause else { return }
        guard let session, session.activationState == .activated, session.isReachable else {
            isReachable = false
            errorMessage = "Open XMWatch on your iPhone to connect."
            return
        }
        let id = UUID()
        commandID = id
        isCommandPending = true
        errorMessage = nil
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            self?.finish(id: id, error: "iPhone did not respond. Try refreshing.")
        }
        // Commands are immediate only: never queue a play/pause for later delivery.
        session.sendMessage(["command": command.rawValue], replyHandler: { [weak self] reply in
            Task { @MainActor in
                self?.accept(reply)
                self?.finish(id: id, error: reply["error"] as? String)
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in self?.finish(id: id, error: "Could not reach iPhone. Try again.") }
        })
    }

    private func finish(id: UUID, error: String?) {
        guard commandID == id else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        commandID = nil
        isCommandPending = false
        errorMessage = error
    }

    private func accept(_ payload: [String: Any]) {
        inbox.accept(payload)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            #if os(watchOS)
            self.accept(session.receivedApplicationContext)
            if session.isReachable { self.refresh() }
            #else
            self.publish(self.snapshot())
            #endif
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            if self.isReachable { self.refresh() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.accept(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.accept(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            #if os(iOS)
            guard let raw = message["command"] as? String, let command = PhonePlaybackCommand(rawValue: raw),
                  let service = self.service else { replyHandler(["error": "Unknown command."]); return }
            if command == .refresh { replyHandler(self.snapshot().payload); return }
            // Pause must be able to cancel an in-flight channel change.
            if command == .pause {
                service.pausePlayback()
            } else {
                guard !self.phoneCommandInProgress else { replyHandler(["error": "iPhone is changing channels."]); return }
                guard service.isConfigured, service.status == .ready else {
                    replyHandler(["error": "Open XMWatch and sign in on iPhone."]); return
                }
                self.phoneCommandInProgress = true
                defer { self.phoneCommandInProgress = false }
                switch command {
                case .play:
                    guard service.currentChannel != nil else {
                        replyHandler(["error": "Choose a channel on iPhone first."]); return
                    }
                    service.resumePlayback()
                case .next: await service.nextChannel()
                case .previous: await service.previousChannel()
                default: break
                }
            }
            let state = self.snapshot()
            self.publish(state)
            replyHandler(state.payload)
            #else
            replyHandler(["error": "Playback commands must be sent to iPhone."])
            #endif
        }
    }

    #if os(iOS)
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.publish(self.snapshot()) }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
