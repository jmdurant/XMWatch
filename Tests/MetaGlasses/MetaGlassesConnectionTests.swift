import XCTest
import MWDATCore
import MWDATMockDevice
@testable import XMWatch

@MainActor
final class MetaGlassesConnectionTests: XCTestCase {
    override func setUp() async throws {
        try await MainActor.run {
            _ = try XCTUnwrap(MetaGlassesAudioPlayerController.configureWearables(),
                "DAT configuration failed; keep simulator code signing enabled for SDK keychain access")
        }
    }

    func testGlassesConnectWaitsForDiscoveryAndCanReconnect() async throws {
        MockDeviceKit.shared.enable()
        let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
        let controller = MetaGlassesAudioPlayerController(wearables: Wearables.shared, playback: RadioPlaybackSpy())
        addTeardownBlock { @MainActor in
            await controller.disconnect()
            await MockDeviceKit.shared.disable()
        }
        await settleRegistration()
        controller.connect() // Tap before Bluetooth discovery/compatibility has completed.
        await settleRegistration()
        XCTAssertEqual(controller.connectionState, .connecting)
        glasses.powerOn()
        glasses.unfold()
        glasses.don()
        try await waitForGlasses { controller.isDisplayReady }
        XCTAssertEqual(controller.connectionState, .connected)
        XCTAssertFalse(controller.canConnect)
        controller.connect() // Repeated taps must not create a second SDK session.
        XCTAssertEqual(controller.connectionState, .connected)
        await controller.disconnect()
        XCTAssertFalse(controller.isDisplayReady)
        XCTAssertFalse(controller.isUpdatingPlayback)
        controller.connect()
        try await waitForGlasses { controller.isDisplayReady }
        XCTAssertNil(controller.lastError)
        XCTAssertTrue(controller.isUpdatingPlayback)
        glasses.fold()
        try await waitForGlasses { controller.connectionState == .disconnected }
        XCTAssertFalse(controller.isDisplayReady)
        XCTAssertFalse(controller.isUpdatingPlayback)
        XCTAssertNotNil(controller.lastError, "The stopped event must retain the SDK's session-ended error")
        glasses.unfold()
        glasses.don()
        controller.connect()
        try await waitForGlasses { controller.isDisplayReady }
        XCTAssertNil(controller.lastError, "An explicit retry clears the previous failure")
    }

    func testGlassesDisconnectCancelsPendingDiscovery() async throws {
        MockDeviceKit.shared.enable()
        let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
        let controller = MetaGlassesAudioPlayerController(wearables: Wearables.shared, playback: RadioPlaybackSpy())
        addTeardownBlock { @MainActor in
            await controller.disconnect()
            await MockDeviceKit.shared.disable()
        }
        await settleRegistration()
        controller.connect()
        await controller.disconnect()
        glasses.powerOn()
        glasses.unfold()
        glasses.don()
        try await waitForGlasses { controller.detectedDevices.contains { $0.state.linkState == .connected } }
        XCTAssertEqual(controller.connectionState, .disconnected)
        XCTAssertFalse(controller.isDisplayReady)
        XCTAssertFalse(controller.isUpdatingPlayback)
        XCTAssertTrue(controller.canConnect)
    }

    func testGlassesTimeoutKeepsErrorAndDoesNotConnectToLateDevice() async throws {
        MockDeviceKit.shared.enable()
        let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
        let controller = MetaGlassesAudioPlayerController(
            wearables: Wearables.shared, playback: RadioPlaybackSpy(), connectionTimeout: .milliseconds(150))
        addTeardownBlock { @MainActor in
            await controller.disconnect()
            await MockDeviceKit.shared.disable()
        }
        await settleRegistration()
        controller.connect()
        try await waitForGlasses { controller.connectionState == .disconnected }
        let error = try XCTUnwrap(controller.lastError)
        XCTAssertTrue(error.contains("Meta AI"))
        glasses.powerOn()
        glasses.unfold()
        glasses.don()
        try await waitForGlasses { controller.detectedDevices.contains { $0.state.linkState == .connected } }
        XCTAssertEqual(controller.lastError, error)
        XCTAssertFalse(controller.isDisplayReady)
        XCTAssertFalse(controller.isUpdatingPlayback)
        XCTAssertFalse(controller.hasConnectionAttempt)
    }

    func testGlassesWithoutDisplayExplainWhyPlayerCannotConnect() async throws {
        MockDeviceKit.shared.enable()
        let glasses = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
        let controller = MetaGlassesAudioPlayerController(
            wearables: Wearables.shared, playback: RadioPlaybackSpy(), connectionTimeout: .milliseconds(150))
        addTeardownBlock { @MainActor in
            await controller.disconnect()
            await MockDeviceKit.shared.disable()
        }
        glasses.powerOn()
        glasses.unfold()
        glasses.don()
        try await waitForGlasses { !controller.detectedDevices.isEmpty }
        controller.connect()
        try await waitForGlasses { controller.connectionState == .disconnected }
        XCTAssertTrue(controller.lastError?.contains("do not have a display") == true)
        XCTAssertFalse(controller.isDisplayReady)
        XCTAssertFalse(controller.isUpdatingPlayback)
    }

    func testGlassesRequireRegistrationBeforeConnecting() async {
        MockDeviceKit.shared.enable(config: MockDeviceKitConfig(initiallyRegistered: false))
        let controller = MetaGlassesAudioPlayerController(wearables: Wearables.shared, playback: RadioPlaybackSpy())
        addTeardownBlock { @MainActor in
            await controller.disconnect()
            await MockDeviceKit.shared.disable()
        }
        await settleRegistration()
        controller.connect()
        XCTAssertFalse(controller.hasConnectionAttempt)
        XCTAssertFalse(controller.canConnect)
        XCTAssertTrue(controller.lastError?.contains("Register XMWatch") == true)
    }

    private func waitForGlasses(
        timeout: TimeInterval = 10,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Timed out waiting for Meta glasses state")
        if !condition() { throw CancellationError() }
    }

    func testUnavailableSDKDoesNotAccessSharedWearables() async {
        let controller = MetaGlassesAudioPlayerController(wearables: nil, playback: RadioPlaybackSpy())
        XCTAssertFalse(controller.isAvailable)
        controller.startRegistration()
        controller.connect()
        controller.unregister()
        controller.openDATGlassesAppUpdate()
        controller.openFirmwareUpdate()
        controller.refreshDevices()
        let handled = await controller.handleOpenURL(URL(string: "xmwatch://test")!)
        XCTAssertFalse(handled)
        XCTAssertEqual(controller.connectionState, .disconnected)
        XCTAssertFalse(controller.isUpdatingPlayback)
    }

    func testHostDeclaresRequiredDisplayLinkConfiguration() {
        let info = Bundle.main.infoDictionary ?? [:]
        let modes = Set(info["UIBackgroundModes"] as? [String] ?? [])
        XCTAssertTrue(Set(["audio", "bluetooth-central", "bluetooth-peripheral", "external-accessory"]).isSubset(of: modes))
        XCTAssertTrue((info["UISupportedExternalAccessoryProtocols"] as? [String] ?? []).contains("com.meta.ar.wearable"))
        XCTAssertTrue((info["NSBonjourServices"] as? [String] ?? []).contains("_bonjour._tcp"))
        XCTAssertFalse((info["NSBluetoothAlwaysUsageDescription"] as? String ?? "").isEmpty)
        XCTAssertFalse((info["NSLocalNetworkUsageDescription"] as? String ?? "").isEmpty)
        let dat = info["MWDAT"] as? [String: Any]
        XCTAssertEqual(dat?["AppLinkURLScheme"] as? String, "xmwatch://")
        XCTAssertFalse((dat?["TeamID"] as? String ?? "").isEmpty)
        let urlTypes = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        XCTAssertTrue(urlTypes.contains { ($0["CFBundleURLSchemes"] as? [String] ?? []).contains("xmwatch") })
        XCTAssertTrue((info["LSApplicationQueriesSchemes"] as? [String] ?? []).contains("fb-viewapp"))
    }

    func testRadioButtonsControlPhoneAndRejectStaleCommands() async throws {
        MockDeviceKit.shared.enable()
        let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
        let playback = RadioPlaybackSpy()
        playback.glassesSnapshot = RadioGlassesSnapshot(channelID: "hits1", channelName: "Hits 1",
            channelNumber: "2", song: "Test Song", artist: "Test Artist", wantsPlayback: true,
            isBuffering: true)
        let controller = MetaGlassesAudioPlayerController(wearables: Wearables.shared, playback: playback)
        addTeardownBlock { @MainActor in
            await controller.disconnect()
            await MockDeviceKit.shared.disable()
        }
        glasses.powerOn()
        glasses.unfold()
        glasses.don()
        await settleRegistration()
        controller.connect()
        try await waitForGlasses { controller.isDisplayReady }
        let buttons = controller.transportButtons(for: playback.glassesSnapshot).buttons
        XCTAssertEqual(buttons.map(\.label), ["Previous", "Pause", "Next"],
            "Buffering must still let the user cancel playback")
        buttons[0].onClick?()
        try await waitForGlasses { playback.commands == ["previous"] }
        buttons[1].onClick?()
        try await waitForGlasses { playback.commands == ["previous", "toggle"] }
        XCTAssertFalse(playback.glassesSnapshot.wantsPlayback)
        XCTAssertEqual(controller.transportButtons(for: playback.glassesSnapshot).buttons[1].label, "Play")
        buttons[2].onClick?()
        try await waitForGlasses { playback.commands == ["previous", "toggle", "next"] }

        // Signing out/clearing the channel must make already-rendered controls inert.
        let channel = playback.glassesSnapshot
        playback.glassesSnapshot = RadioGlassesSnapshot()
        for button in buttons { button.onClick?() }
        await settleRegistration()
        XCTAssertEqual(playback.commands.count, 3)
        playback.glassesSnapshot = channel
        await controller.disconnect()
        for button in buttons { button.onClick?() }
        await settleRegistration()
        XCTAssertEqual(playback.commands.count, 3)
        controller.connect()
        try await waitForGlasses { controller.isDisplayReady }
        for button in buttons { button.onClick?() }
        await settleRegistration()
        XCTAssertEqual(playback.commands.count, 3, "Old connection callbacks cannot control a new session")
        controller.transportButtons(for: playback.glassesSnapshot).buttons[1].onClick?()
        try await waitForGlasses { playback.commands.count == 4 }
    }

    private func settleRegistration() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
