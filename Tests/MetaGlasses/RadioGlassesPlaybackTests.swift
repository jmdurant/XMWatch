import XCTest
@testable import XMWatch

@MainActor
final class RadioPlaybackSpy: MetaGlassesRadioPlayback {
    var glassesSnapshot = RadioGlassesSnapshot()
    private(set) var commands: [String] = []

    func togglePlayback() {
        commands.append("toggle")
        glassesSnapshot.wantsPlayback.toggle()
    }
    func nextChannel() async { commands.append("next") }
    func previousChannel() async { commands.append("previous") }
}

@MainActor
final class RadioGlassesPlaybackTests: XCTestCase {
    func testLiveRadioMetadataAndPlaybackIntent() {
        var snapshot = RadioGlassesSnapshot(channelID: "hits1", channelName: "Hits 1",
            channelNumber: "2", song: "Test Song", artist: "Test Artist", wantsPlayback: true)
        XCTAssertEqual(snapshot.title, "Test Song")
        XCTAssertEqual(snapshot.subtitle, "Test Artist")
        XCTAssertEqual(snapshot.channelLine, "Ch. 2 · Hits 1")
        XCTAssertEqual(snapshot.statusLine, "Live")
        snapshot.isBuffering = true
        XCTAssertEqual(snapshot.statusLine, "Tuning...")
        XCTAssertEqual(snapshot.playPauseLabel, "Pause")
        snapshot.isReconnecting = true
        XCTAssertEqual(snapshot.statusLine, "Reconnecting...")
        snapshot.wantsPlayback = false
        XCTAssertEqual(snapshot.statusLine, "Paused")
        XCTAssertEqual(snapshot.playPauseLabel, "Play")
    }

    func testMissingMetadataFallsBackToChannelAndEmptyPlayerClearsCard() {
        var snapshot = RadioGlassesSnapshot(channelID: "talk", channelName: "Talk Radio",
            channelNumber: "100", song: " ", artist: "")
        XCTAssertEqual(snapshot.title, "Talk Radio")
        XCTAssertEqual(snapshot.subtitle, "Ch. 100 · Talk Radio")
        snapshot = RadioGlassesSnapshot()
        XCTAssertFalse(snapshot.hasChannel)
        XCTAssertEqual(snapshot.title, "XMWatch")
        XCTAssertEqual(snapshot.subtitle, "Start a channel on your iPhone")
        XCTAssertEqual(snapshot.statusLine, "Nothing playing")
    }

    func testAdapterReadsPhoneServiceAndClearsWhenChannelIsRemoved() {
        let service = XMRadioService(configureEnvironment: { _ in })
        XCTAssertFalse(service.glassesSnapshot.hasChannel)
        service.currentChannel = XMChannel(id: "hits1", number: "2", name: "Hits 1",
            category: "Pop", mediumImageURL: "", largeImageURL: "")
        XCTAssertEqual(service.glassesSnapshot.channelID, "hits1")
        XCTAssertEqual(service.glassesSnapshot.title, "Hits 1")
        XCTAssertEqual(service.glassesSnapshot.statusLine, "Paused")
        service.currentChannel = nil
        XCTAssertEqual(service.glassesSnapshot, RadioGlassesSnapshot())
    }
}
