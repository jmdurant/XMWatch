import AVFoundation
import Foundation

// Replace device playback only; each test target compiles the actual app service.
func writeDebug(_ message: String) {}

@MainActor
final class AVPlayerController {
    static var playedURLs: [URL] = []
    var player: AVPlayer?
    var isSuspended = false
    var onPropertyChange: ((PlayerProperty, Any?) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onPlaybackFailed: ((Error?) -> Void)?
    var onPlaybackStalled: (() -> Void)?
    var onMediaLoaded: (() -> Void)?
    var onPauseRequested: (() -> Void)?
    private(set) var destroyed = false
    private(set) var paused = false
    init(options: PlayerOptions) {}
    func play(_ url: URL) { Self.playedURLs.append(url) }
    func pause() { paused = true }
    func destruct() { destroyed = true }
    func logPlayerState() {}
}
typealias WatchAVPlayerController = AVPlayerController

@MainActor
final class NowPlayingManager {
    var onTogglePlayback: (() -> Void)?
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onNextChannel: (() -> Void)?
    var onPreviousChannel: (() -> Void)?
    private(set) var invalidated = false
    init(coordinator: AVPlayerController) {}
    func updateMetadata(title: String, artist: String, channel: XMChannel, artworkURL: URL?) {}
    func updatePlaybackState(rate: Double) {}
    func invalidate() { invalidated = true }
}
typealias WatchNowPlayingManager = NowPlayingManager

@MainActor
final class XMHLSProxyServer {
    static let shared = XMHLSProxyServer()
    var isRunning = false
    var port: UInt16 { isRunning ? 12345 : 0 }
    func start() async throws { isRunning = true }
    func stop() { isRunning = false }
}

final class ControlledURLProtocol: URLProtocol {
    @MainActor static var handler: ((ControlledURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in Self.handler?(self) }
    }
    override func stopLoading() {}
    func respond(_ json: [String: Any], status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
}
