import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import XMRadioCore

private func metadata(_ markers: [[String: Any]], channel: String = "hits") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["ModuleListResponse": ["messages": [["code": 100]],
        "moduleList": ["modules": [["moduleResponse": ["liveChannelData": ["channelId": channel,
            "markerLists": [["layer": "cut", "markers": markers]]]]]]]]])
}
private func marker(_ time: Any, duration: Double, title: String? = nil) -> [String: Any] {
    var value: [String: Any] = ["timestamp": ["absolute": time], "duration": duration]
    if let title { value["cut"] = ["title": title, "artists": [["name": "Artist"]], "album": ["creativeArts": [
        ["size": "MEDIUM", "relativeUrl": "%Album_Art%/fixture_m.jpg"]]] ] }
    return value
}

@Test func metadataTracksAudibleMarkerAndBoundaryInsteadOfNewestSong() throws {
    let data = try metadata([marker("1000000000000", duration: 30, title: "Audible"),
                             marker("1000000030000", duration: 20, title: "Future")])
    let value = try RadioAPI.nowPlaying(data: data, status: 200, channelID: "hits", audibleDate: Date(timeIntervalSince1970: 1_000_000_025))
    #expect(value.title == "Audible")
    #expect(value.artist == "Artist")
    #expect(value.nextPollSeconds == 5)
    #expect(value.artworkURL?.absoluteString == "https://albumart.siriusxm.com/fixture_m.jpg")
    let boundary = try RadioAPI.nowPlaying(data: data, status: 200, channelID: "hits", audibleDate: Date(timeIntervalSince1970: 1_000_000_030))
    #expect(boundary.title == "Future")
}

@Test func promosAndGapsClearStaleSongMetadata() throws {
    let data = try metadata([marker("1000", duration: 10, title: "Old"), marker("1010", duration: 15)])
    let promo = try RadioAPI.nowPlaying(data: data, status: 200, channelID: "hits", audibleDate: Date(timeIntervalSince1970: 1012))
    #expect(promo.title == nil && promo.artist == nil && promo.artworkURL == nil)
    let gap = try RadioAPI.nowPlaying(data: data, status: 200, channelID: "hits", audibleDate: Date(timeIntervalSince1970: 1030))
    #expect(gap.title == nil)
    #expect(gap.nextPollSeconds == 2)
}

@Test func metadataAcceptsISOTimeAndRejectsAnotherChannel() throws {
    let data = try metadata([marker("2026-10-20T12:00:00.000Z", duration: 60, title: "ISO")])
    let time = ISO8601DateFormatter().date(from: "2026-10-20T12:00:30Z")!
    #expect(try RadioAPI.nowPlaying(data: data, status: 200, channelID: "hits", audibleDate: time).title == "ISO")
    #expect(throws: RadioAPIError.malformedResponse) { try RadioAPI.nowPlaying(data: data, status: 200, channelID: "another", audibleDate: time) }
    let bad = try metadata([marker("not-a-date", duration: 60, title: "Invalid")])
    #expect(try RadioAPI.nowPlaying(data: bad, status: 200, channelID: "hits", audibleDate: time).title == nil)
}

@Test func metadataRequestUsesSelectedRegionAndEscapesChannel() throws {
    let request = try RadioAPI(region: .canada, deviceID: "fixture").nowPlayingRequest(channelID: "test&channel")
    let url = try #require(request.url)
    #expect(url.host == "player.siriusxm.ca")
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "channelId" }?.value == "test&channel")
    #expect(request.timeoutInterval == 8)
}

@Test func metadataAcceptsProviderTimezoneWithoutColon() throws {
    let data = try metadata([marker("2026-10-20T22:09:13.241+0000", duration: 136.349, title: "Provider format")])
    let time = ISO8601DateFormatter().date(from: "2026-10-20T22:10:00Z")!
    #expect(try RadioAPI.nowPlaying(data: data, status: 200, channelID: "hits", audibleDate: time).title == "Provider format")
}

@Test func liveCutWithoutFinalDurationRemainsCurrentUntilNextCut() throws {
    let data = try metadata([marker("1000", duration: 20, title: "Completed"),
        marker("1020", duration: 0, title: "Live"), marker("1100", duration: 20, title: "Next")])
    #expect(try RadioAPI.nowPlaying(data: data, status: 200, channelID: "hits", audibleDate: Date(timeIntervalSince1970: 1050)).title == "Live")
    #expect(try RadioAPI.nowPlaying(data: data, status: 200, channelID: "hits", audibleDate: Date(timeIntervalSince1970: 1100)).title == "Next")
    #expect(try RadioAPI.nowPlaying(data: data, status: 200, channelID: "hits", audibleDate: Date(timeIntervalSince1970: 1130)).title == nil)
}

@Test func openEndedPromoClearsSongAndDoesNotPollContinuously() throws {
    let data = try metadata([marker("1000", duration: 0, title: "Song"), marker("1100", duration: 0)])
    let current = try RadioAPI.nowPlaying(data: data, status: 200, channelID: "hits", audibleDate: Date(timeIntervalSince1970: 1120))
    #expect(current.title == nil && current.artist == nil)
    #expect(current.nextPollSeconds == 8)
}
