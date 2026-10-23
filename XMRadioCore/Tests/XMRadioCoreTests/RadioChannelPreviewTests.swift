import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import XMRadioCore

private func previewEnvelope(_ rows: [[String: Any]], code: Int = 100) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["ModuleListResponse": ["status": code,
        "messages": [["code": code]], "moduleList": ["modules": [["moduleResponse": [
            "moduleDetails": ["liveChannelResponse": ["liveChannelResponses": rows]]]]]]]])
}
private func previewCut(_ title: String?, artist: String? = "Artist", start: Any? = nil, duration: Any? = nil,
                        kind: String? = nil) -> [String: Any] {
    var marker: [String: Any] = [:]
    if let start { marker["timestamp"] = ["absolute": start] }
    if let duration { marker["duration"] = duration }
    if let title {
        var cut: [String: Any] = ["title": title]
        if let artist { cut["artists"] = [["name": artist]] }
        if let kind { cut["cutContentType"] = kind }
        marker["cut"] = cut
    }
    return marker
}
private func previewRow(_ id: String, _ markers: [[String: Any]], layer: String = "cut") -> [String: Any] {
    ["channelId": id, "markerLists": [["layer": layer, "markers": markers]]]
}

@Test(arguments: RadioRegion.allCases)
func channelPreviewRequestMatchesBulkAppleEndpoint(region: RadioRegion) throws {
    let request = try RadioAPI(region: region, deviceID: "fixture").channelPreviewsRequest(now: Date(timeIntervalSince1970: 123))
    let url = try #require(request.url)
    let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    #expect(url.scheme == "https" && url.host == region.host)
    #expect(url.path == "/rest/v2/experience/modules/get/discover-channel-list")
    #expect(query == ["type": "2", "batch-mode": "true", "format": "json", "request-option": "discover-channel-list-withpdt", "result-template": "web", "time": "123000"])
    #expect(request.httpMethod == "GET" && request.httpBody == nil)
    #expect(request.timeoutInterval == 8 && request.cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
}

@Test func channelPreviewActualNestingSelectsCurrentInsteadOfAnnouncedFuture() throws {
    let current = previewCut("Current", start: "1000000000000", duration: 30)
    let future = previewCut("Future", start: 1_000_000_030_000 as Int64, duration: 60)
    let data = try previewEnvelope([previewRow("provider-id", [future, current]),
        previewRow("only-future", [future]), previewRow("episode-layer", [current], layer: "episode")])
    let result = try RadioAPI.channelPreviews(data: data, status: 200, now: Date(timeIntervalSince1970: 1_000_000_025))
    #expect(result["provider-id"] == RadioChannelPreview(title: "Current", artist: "Artist"))
    #expect(result["only-future"] == RadioChannelPreview(title: nil, artist: nil))
    #expect(result["episode-layer"] == RadioChannelPreview(title: nil, artist: nil))
    let boundary = try RadioAPI.channelPreviews(data: data, status: 200, now: Date(timeIntervalSince1970: 1_000_000_030))
    #expect(boundary["provider-id"]?.title == "Future")
}

@Test func channelPreviewPromosGapsAndOpenEndedCutsClearStaleSongs() throws {
    let song = previewCut("Old", start: "1000", duration: 200)
    let promo = previewCut(nil, start: "1010", duration: 10)
    let data = try previewEnvelope([previewRow("promo", [song, promo]),
        previewRow("link", [previewCut("Link title", kind: "Link")]),
        previewRow("exp", [previewCut("Experience title", kind: "Exp")]),
        previewRow("open", [previewCut("Live", start: "1000", duration: 0), previewCut("Next", start: "1100", duration: 30)]),
        previewRow("invalid-date", [previewCut("Do not guess", start: "invalid", duration: 30)]),
        previewRow("invalid-duration", [previewCut("Do not assume live", start: "1000", duration: "invalid")])])
    let active = try RadioAPI.channelPreviews(data: data, status: 200, now: Date(timeIntervalSince1970: 1015))
    for id in ["promo", "link", "exp", "invalid-date", "invalid-duration"] {
        #expect(active[id] == RadioChannelPreview(title: nil, artist: nil))
    }
    #expect(active["open"]?.title == "Live")
    let gap = try RadioAPI.channelPreviews(data: data, status: 200, now: Date(timeIntervalSince1970: 1025))
    #expect(gap["promo"] == RadioChannelPreview(title: nil, artist: nil))
    let ended = try RadioAPI.channelPreviews(data: data, status: 200, now: Date(timeIntervalSince1970: 1131))
    #expect(ended["open"] == RadioChannelPreview(title: nil, artist: nil))
    var spot = previewCut("Commercial")
    var cut = spot["cut"] as! [String: Any]
    cut["memberOfSpotBlock"] = true; spot["cut"] = cut
    #expect(try RadioAPI.channelPreviews(data: previewEnvelope([previewRow("spot", [spot])]), status: 200)["spot"] == RadioChannelPreview(title: nil, artist: nil))
}

@Test func channelPreviewUndatedFirstCutAndSanitizationDoNotInventMetadata() throws {
    let first = previewCut("  Current\n \u{202E}Song\u{0000} ", artist: " Artist\tName ")
    let result = try RadioAPI.channelPreviews(data: previewEnvelope([
        previewRow("hits", [first, previewCut("Next")]),
        previewRow("partial", [previewCut("Talk title", artist: nil)]),
        previewRow("missing", []), previewRow("hits", [previewCut("Duplicate")]),
        previewRow("bad\nidentity", [first]), previewRow("long", [previewCut(String(repeating: "a", count: 1000))])]), status: 200)
    #expect(result["hits"] == RadioChannelPreview(title: "Current Song", artist: "Artist Name"))
    #expect(result["partial"] == RadioChannelPreview(title: "Talk title", artist: nil))
    #expect(result["missing"] == RadioChannelPreview(title: nil, artist: nil))
    #expect(result["bad\nidentity"] == nil)
    #expect(result["long"]?.title?.count == 256)
}

@Test func channelPreviewISOTimeAndMalformedResponsesAreHandledExplicitly() throws {
    let data = try previewEnvelope([previewRow("iso", [previewCut("ISO", start: "2026-10-22T14:00:00.000+0000", duration: 60)])])
    let now = ISO8601DateFormatter().date(from: "2026-10-22T14:00:30Z")!
    #expect(try RadioAPI.channelPreviews(data: data, status: 200, now: now)["iso"]?.title == "ISO")
    #expect(try RadioAPI.channelPreviews(data: previewEnvelope([]), status: 200).isEmpty)
    #expect(throws: RadioAPIError.http(401)) { try RadioAPI.channelPreviews(data: data, status: 401) }
    #expect(throws: RadioAPIError.authenticationRejected) { try RadioAPI.channelPreviews(data: previewEnvelope([], code: 101), status: 200) }
    #expect(throws: RadioAPIError.provider(999)) { try RadioAPI.channelPreviews(data: previewEnvelope([], code: 999), status: 200) }
    #expect(throws: RadioAPIError.malformedResponse) { try RadioAPI.channelPreviews(data: Data(#"{"ModuleListResponse":{}}"#.utf8), status: 200) }
    #expect(throws: RadioAPIError.malformedResponse) { try RadioAPI.channelPreviews(data: Data(repeating: 32, count: 8 * 1024 * 1024 + 1), status: 200) }
    #expect(throws: RadioAPIError.malformedResponse) { try RadioAPI.channelPreviews(data: previewEnvelope(Array(repeating: previewRow("id", []), count: 2049)), status: 200) }
}

private actor ChannelPreviewClientFixture {
    private(set) var paths: [String] = []
    private var logins = 0
    private var bulkStarted = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var bulkWaiter: CheckedContinuation<Void, Never>?
    let holdBulk: Bool
    init(holdBulk: Bool = false) { self.holdBulk = holdBulk }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        paths.append(url.path)
        #expect(!request.httpShouldHandleCookies)
        var headers: [String: String] = [:]
        let data: Data
        if url.path.hasSuffix("authentication") {
            logins += 1
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            headers["Set-Cookie"] = "AUTH=login\(logins); Path=/; Secure"
            data = try JSONSerialization.data(withJSONObject: ["ModuleListResponse": ["moduleList": ["modules": [["moduleResponse": ["authenticationData": ["username": "fixture"]]]]]]])
        } else if url.path.hasSuffix("resume") {
            #expect(request.value(forHTTPHeaderField: "Cookie") == "AUTH=login\(logins)")
            headers["Set-Cookie"] = "V2ONLY=fixture; Path=/rest/v2; Secure"
            data = try JSONSerialization.data(withJSONObject: ["ModuleListResponse": ["moduleList": ["modules": [["moduleResponse": ["liveChannelData": [
                "customAudioInfos": [["chunks": ["chunks": [["key": Data(repeating: 1, count: 16).base64EncodedString(), "keyUrl": "%Live_Primary_HLS%/key/1"]]]]], "hlsConsumptionInfo": "?fixture=session"]]]]]]])
        } else if url.path.hasSuffix("discover-channel-list") {
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("AUTH=login\(logins)") == true)
            #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("V2ONLY=fixture") == true)
            bulkStarted = true; startWaiter?.resume(); startWaiter = nil
            if holdBulk {
                await withCheckedContinuation { bulkWaiter = $0 }
                headers["Set-Cookie"] = "AUTH=stale-preview; Path=/; Secure"
            }
            data = try previewEnvelope([previewRow("hits", [previewCut("Bulk listing")]), previewRow("second", [])])
        } else if url.path.hasSuffix("now-playing-live") {
            #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("V2ONLY") == false)
            data = try JSONSerialization.data(withJSONObject: ["ModuleListResponse": ["moduleList": ["modules": [["moduleResponse": ["liveChannelData": ["channelId": "hits", "markerLists": [["layer": "cut", "markers": [previewCut("Audible song", start: "1000", duration: 60)]]]]]]]]]])
        } else { throw RadioAPIError.malformedResponse }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
    func waitForBulk() async {
        if bulkStarted { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func releaseBulk() { bulkWaiter?.resume(); bulkWaiter = nil }
}

@Test func channelPreviewClientUsesOneCookieScopedBulkRequestAndSeparateAudibleMetadata() async throws {
    let fixture = ChannelPreviewClientFixture()
    let client = RadioClient(region: .us, deviceID: "fixture", transport: { try await fixture.send($0) })
    do {
        _ = try await client.channelPreviews()
        Issue.record("Unauthenticated bulk lookup was accepted")
    } catch let error as RadioRequestFailure {
        #expect(error.stage == .metadata && error.reason == .authenticationRejected)
    }
    #expect(await fixture.paths.isEmpty)
    _ = try await client.signIn(username: "fixture", password: "fixture")
    let previews = try await client.channelPreviews()
    #expect(previews["hits"]?.title == "Bulk listing")
    #expect(previews["second"] == RadioChannelPreview(title: nil, artist: nil))
    let audible = try await client.nowPlaying(channelID: "hits", audibleDate: Date(timeIntervalSince1970: 1005))
    #expect(audible.title == "Audible song")
    #expect(await fixture.paths.filter { $0.hasSuffix("discover-channel-list") }.count == 1)
    #expect(await fixture.paths.count == 4)
}

@Test func channelPreviewAccountGenerationRejectsLateResponseBeforeMergingCookies() async throws {
    let fixture = ChannelPreviewClientFixture(holdBulk: true)
    let client = RadioClient(region: .us, deviceID: "fixture", transport: { try await fixture.send($0) })
    _ = try await client.signIn(username: "first", password: "fixture")
    let pending = Task { try await client.channelPreviews() }
    await fixture.waitForBulk()
    _ = try await client.signIn(username: "second", password: "fixture")
    await fixture.releaseBulk()
    await #expect(throws: CancellationError.self) { try await pending.value }
    let saved = try await client.savedSession()
    #expect(saved.contains("login2") && !saved.contains("stale-preview"))
}
