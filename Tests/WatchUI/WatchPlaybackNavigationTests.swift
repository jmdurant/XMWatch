import XCTest

@MainActor
final class WatchPlaybackNavigationTests: XCTestCase {
    func testSavedPhoneModeOpensMenuAndWatchPlaybackStaysExplicit() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Override defaults only for this process; never resume an account's stream.
        app.launchArguments = ["-xm_playback_device", "phone", "-xm_resume_last_channel", "NO"]
        app.launch()
        XCTAssertTrue(app.navigationBars["XMWatch"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)["watch.player.system"].firstMatch.exists)
        capture(app, "Explicit playback destinations")

        let phone = app.buttons["watch.phone.nowPlaying"]
        for _ in 0..<4 where !phone.isHittable { app.swipeUp() }
        phone.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 10))
        // This simulator has no paired phone. Its system player must not appear.
        XCTAssertFalse(app.descendants(matching: .any)["watch.player.system"].firstMatch.exists)
        capture(app, "iPhone controls without a hidden device picker")

        let watch = app.buttons["watch.phone.watchPlayer"]
        for _ in 0..<5 where !watch.isHittable { app.swipeUp() }
        watch.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["watch.player.channels"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["watch.player.system"].firstMatch.exists,
                       "Without local playback, generic Play could resume the phone")
        capture(app, "Standalone watch destination")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["XMWatch"].waitForExistence(timeout: 10))
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
