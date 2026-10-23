import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import XMRadioCore

private func configurationData(settings: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["ModuleListResponse": ["messages": [["code": 100]],
        "moduleList": ["modules": [["moduleResponse": ["configuration": ["components": [
            ["name": "relativeUrls", "settings": settings]
        ]]]]]]]])
}

@Test func configurationSupportsLiveSettingsArrayAndCachedShape() throws {
    let rows = [["name": "Live_Primary_HLS", "url": "https://radio.example.com"]]
    let live = try configurationData(settings: [["relativeUrls": rows, "platform": "Web"]])
    #expect(try RadioAPI.primaryHLSRoot(data: live, status: 200).host == "radio.example.com")
    let cached = try configurationData(settings: ["relativeUrls": [rows]])
    #expect(try RadioAPI.primaryHLSRoot(data: cached, status: 200).scheme == "https")
    let unsafe = try configurationData(settings: [["relativeUrls": [["name": "Live_Primary_HLS", "url": "http://radio.example.com"]]]])
    #expect(throws: RadioAPIError.malformedResponse) { try RadioAPI.primaryHLSRoot(data: unsafe, status: 200) }
}

@Test func planMatchesApplePlaylistAndSegmentLocations() throws {
    let session = RadioSession(key: Data(repeating: 1, count: 16),
        keyURLTemplate: "%Live_Primary_HLS%/AAC_Data/hits/HLS_hits_32k_v3/key/1",
        consumptionQuery: "?fixture=account")
    let plan = try RadioPlaybackPlan(session: session, primaryRoot: URL(string: "https://radio.example.com/")!,
        channelID: "hits", token: "token+&fixture")
    #expect(plan.playlistURL.path == "/AAC_Data/hits/HLS_hits_256k_v3/hits_256k_medium_v3.m3u8")
    #expect(plan.segmentBaseURL.path == "/AAC_Data/hits/HLS_hits_256k_v3")
    let query = URLComponents(url: plan.playlistURL, resolvingAgainstBaseURL: false)?.queryItems
    #expect(query?.first { $0.name == "token" }?.value == "token+&fixture")
    let encoded = try JSONEncoder().encode(plan)
    let restored = try JSONDecoder().decode(RadioPlaybackPlan.self, from: encoded)
    #expect(restored.key == session.key)
    #expect(restored.playlistURL == plan.playlistURL)
    #expect(throws: RadioAPIError.malformedResponse) {
        try RadioPlaybackPlan(session: session, primaryRoot: URL(string: "https://radio.example.com")!,
            channelID: "../another", token: "fixture")
    }
    let wrongHost = RadioSession(key: session.key, keyURLTemplate: "https://another.example.com/key/1", consumptionQuery: "")
    #expect(throws: RadioAPIError.malformedResponse) {
        try RadioPlaybackPlan(session: wrongHost, primaryRoot: URL(string: "https://radio.example.com")!, channelID: "hits", token: "fixture")
    }
}

@Test func savedCookiesKeepScopeAndRejectAnotherRegion() throws {
    var jar = RadioCookieJar()
    let origin = URL(string: "https://player.siriusxm.com/rest/v2/auth")!
    jar.receive(HTTPURLResponse(url: origin, statusCode: 200, httpVersion: nil,
        headerFields: ["Set-Cookie": "AUTH=fixture; Secure; Path=/, API=v2; Secure; Path=/rest/v2"])!)
    let saved = try JSONDecoder().decode([RadioSavedCookie].self, from: JSONEncoder().encode(jar.snapshot()))
    let restored = try RadioCookieJar(snapshot: saved, region: .us)
    #expect(restored.header(for: URL(string: "https://player.siriusxm.com/rest/v4/get")!) == "AUTH=fixture")
    #expect(restored.header(for: URL(string: "http://player.siriusxm.com/rest/v4/get")!) == nil)
    #expect(throws: RadioAPIError.malformedResponse) { try RadioCookieJar(snapshot: saved, region: .canada) }
    let expired = RadioSavedCookie(name: "AUTH", value: "expired", domain: "player.siriusxm.com", path: "/", secure: true,
        expiry: Date(timeIntervalSince1970: 0))
    #expect(try RadioCookieJar(snapshot: [expired], region: .us).count == 0)
}
