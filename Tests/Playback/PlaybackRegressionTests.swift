import Foundation
import XCTest

@MainActor
final class PlaybackRegressionTests: XCTestCase {
    private var service: XMRadioService!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledURLProtocol.self]
        service = XMRadioService(httpSession: URLSession(configuration: configuration), now: { [unowned self] in self.clock })
        AVPlayerController.playedURLs = []
        ControlledURLProtocol.handler = { request in
            if request.request.httpMethod == "POST" { request.respond(Self.sessionResponse) }
            else { request.respond([:]) }
        }
    }

    override func tearDown() async throws {
        service.signOut()
        ControlledURLProtocol.handler = nil
        service = nil
    }

    private func channel(_ number: String) -> XMChannel {
        XMChannel(id: "channel\(number)", number: number, name: "Channel \(number)", category: "Test", mediumImageURL: "", largeImageURL: "")
    }

    private static var sessionResponse: [String: Any] {
        ["ModuleListResponse": ["moduleList": ["modules": [["moduleResponse": ["liveChannelData": [
            "customAudioInfos": [["chunks": ["chunks": [["key": Data(repeating: 1, count: 16).base64EncodedString(), "keyUrl": "key/1"]]]]],
            "hlsConsumptionInfo": "test"
        ]]]]]]]
    }

    func testPauseDuringTuneNeverInstallsPlayer() async {
        let received = expectation(description: "session request started")
        ControlledURLProtocol.handler = { _ in received.fulfill() }
        let tune = Task { await service.startPlayback(channel: channel("1")) }
        await fulfillment(of: [received], timeout: 2)
        service.pausePlayback()
        let result = await tune.value
        XCTAssertFalse(result)
        XCTAssertFalse(service.userWantsPlayback)
        XCTAssertTrue(service.isPaused)
        XCTAssertFalse(service.isBuffering)
        XCTAssertTrue(AVPlayerController.playedURLs.isEmpty)
    }

    func testNewChannelCancelsOlderTune() async {
        let received = expectation(description: "first channel request")
        ControlledURLProtocol.handler = { _ in received.fulfill() }
        let first = Task { await service.startPlayback(channel: channel("1")) }
        await fulfillment(of: [received], timeout: 2)
        ControlledURLProtocol.handler = { request in
            request.respond(request.request.httpMethod == "POST" ? Self.sessionResponse : [:])
        }
        let second = await service.startPlayback(channel: channel("2"))
        let old = await first.value
        XCTAssertTrue(second)
        XCTAssertFalse(old)
        XCTAssertEqual(service.currentChannel?.number, "2")
        XCTAssertEqual(AVPlayerController.playedURLs.map(\.path), ["/2.m3u8"])
    }

    func testSignOutTearsDownPlayerAndRemoteMetadata() async {
        _ = await service.startPlayback(channel: channel("1"))
        let controller = service.playerController
        let manager = service.nowPlayingManager
        service.signOut()
        XCTAssertEqual(controller?.destroyed, true)
        XCTAssertEqual(manager?.invalidated, true)
        XCTAssertNil(service.playerController)
        XCTAssertNil(service.currentChannel)
        XCTAssertFalse(XMHLSProxyServer.shared.isRunning)
    }

    func testRemotePlayIsIdempotentAndPauseStopsIntent() async {
        _ = await service.startPlayback(channel: channel("1"))
        service.nowPlayingManager?.onPlay?()
        await Task.yield()
        XCTAssertEqual(AVPlayerController.playedURLs.count, 1)
        service.nowPlayingManager?.onPause?()
        XCTAssertFalse(service.userWantsPlayback)
        await service.refreshSessionOnForeground()
        XCTAssertEqual(AVPlayerController.playedURLs.count, 1)
    }

    func testFailedRefreshCanRetryImmediately() async {
        _ = await service.startPlayback(channel: channel("1"))
        clock.addTimeInterval(481)
        var requests = 0
        ControlledURLProtocol.handler = { request in
            guard request.request.httpMethod == "POST" else { request.respond([:]); return }
            requests += 1
            request.respond([:], status: 503)
        }
        let failure = await service.refreshTokenIfNeeded()
        XCTAssertFalse(failure)
        let beforeRetry = requests
        ControlledURLProtocol.handler = { request in
            guard request.request.httpMethod == "POST" else { request.respond([:]); return }
            requests += 1
            request.respond(Self.sessionResponse)
        }
        let success = await service.refreshTokenIfNeeded()
        XCTAssertTrue(success)
        XCTAssertGreaterThan(requests, beforeRetry)
        let afterSuccess = requests
        _ = await service.refreshTokenIfNeeded()
        XCTAssertEqual(requests, afterSuccess)
    }

    func testRefreshRequestsShareOneNetworkOperation() async {
        _ = await service.startPlayback(channel: channel("1"))
        clock.addTimeInterval(481)
        let received = expectation(description: "refresh request")
        var pending: ControlledURLProtocol?
        var count = 0
        ControlledURLProtocol.handler = { request in
            guard request.request.httpMethod == "POST" else { request.respond([:]); return }
            count += 1
            pending = request
            received.fulfill()
        }
        let first = Task { await service.refreshTokenIfNeeded() }
        await fulfillment(of: [received], timeout: 2)
        let second = Task { await service.refreshTokenIfNeeded() }
        await Task.yield()
        pending?.respond(Self.sessionResponse)
        let a = await first.value
        let b = await second.value
        XCTAssertTrue(a && b)
        XCTAssertEqual(count, 1)
    }

    func testLatestActiveMarkerWinsOverSongAndFutureMarkers() async {
        service.currentChannel = channel("1")
        let now = clock
        func marker(_ title: String, offset: Double, duration: Double, kind: String) -> [String: Any] {
            ["assetGUID": title, "layer": "cut", "time": 0,
             "timestamp": ["absolute": ISO8601DateFormatter().string(from: now.addingTimeInterval(offset))],
             "containerGUID": "test", "duration": duration,
             "cut": ["legacyIds": ["siriusXMId": title], "title": title,
                     "artists": [["name": "Artist"]], "cutContentType": kind]]
        }
        let markers = [marker("Future", offset: 60, duration: 100, kind: "Song"),
                       marker("Current link", offset: -10, duration: 30, kind: "Link"),
                       marker("Previous song", offset: -200, duration: 180, kind: "Song")]
        ControlledURLProtocol.handler = { request in
            request.respond(Self.metadata(channelID: "channel1", markers: markers))
        }
        await service.updateNowPlaying()
        XCTAssertEqual(service.nowPlayingSong, "Current link")
        clock.addTimeInterval(500)
        await service.updateNowPlaying()
        XCTAssertNil(service.nowPlayingSong)
    }

    func testMetadataResponseCannotOverwriteAnotherChannel() async {
        service.currentChannel = channel("1")
        let received = expectation(description: "metadata request")
        var pending: ControlledURLProtocol?
        ControlledURLProtocol.handler = { request in pending = request; received.fulfill() }
        let fetch = Task { await service.updateNowPlaying() }
        await fulfillment(of: [received], timeout: 2)
        service.currentChannel = channel("2")
        pending?.respond(Self.metadata(channelID: "channel1", markers: [[
            "assetGUID": "old", "layer": "cut", "time": 0,
            "timestamp": ["absolute": ISO8601DateFormatter().string(from: clock.addingTimeInterval(-10))],
            "containerGUID": "test", "duration": 200,
            "cut": ["legacyIds": ["siriusXMId": "old"], "title": "Old channel title",
                    "artists": [["name": "Old artist"]], "cutContentType": "Song"]
        ]]))
        await fetch.value
        XCTAssertEqual(service.currentChannel?.number, "2")
        XCTAssertNil(service.nowPlayingSong)
    }

    func testSignOutDuringTuneNeverInstallsPlayer() async {
        let received = expectation(description: "session request started")
        ControlledURLProtocol.handler = { _ in received.fulfill() }
        let tune = Task { await service.startPlayback(channel: channel("1")) }
        await fulfillment(of: [received], timeout: 2)
        service.signOut()
        let result = await tune.value
        XCTAssertFalse(result)
        XCTAssertNil(service.currentChannel)
        XCTAssertTrue(AVPlayerController.playedURLs.isEmpty)
    }

    func testPauseCancelsScheduledRecovery() async throws {
        _ = await service.startPlayback(channel: channel("1"))
        service.playerController?.onPlaybackFailed?(nil)
        await Task.yield()
        service.pausePlayback()
        try await Task.sleep(for: .seconds(2.2))
        XCTAssertEqual(AVPlayerController.playedURLs.count, 1)
        XCTAssertFalse(service.isReconnecting)
        XCTAssertFalse(service.userWantsPlayback)
    }

    func testPauseCancelsQueuedResume() async {
        _ = await service.startPlayback(channel: channel("1"))
        service.pausePlayback()
        service.resumePlayback()
        service.pausePlayback()
        await Task.yield()
        XCTAssertEqual(AVPlayerController.playedURLs.count, 1)
        XCTAssertFalse(service.userWantsPlayback)
    }

    func testMalformedSuccessfulHTTPResponseDoesNotCountAsRefresh() async {
        _ = await service.startPlayback(channel: channel("1"))
        clock.addTimeInterval(481)
        ControlledURLProtocol.handler = { request in request.respond([:]) }
        let result = await service.refreshTokenIfNeeded()
        XCTAssertFalse(result)
    }

    private static func metadata(channelID: String, markers: [[String: Any]]) -> [String: Any] {
        ["ModuleListResponse": ["messages": [], "status": 1, "moduleList": ["modules": [[
            "moduleArea": "test", "moduleType": "test", "updateFrequency": 12, "wallClockRenderTime": "",
            "moduleResponse": ["liveChannelData": ["channelId": channelID,
                "markerLists": [["layer": "cut", "markers": markers]]]]
        ]]]]]
    }
}
