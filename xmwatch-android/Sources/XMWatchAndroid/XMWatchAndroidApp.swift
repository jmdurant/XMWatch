import Foundation
import SkipFuse
import SwiftUI

/// A logger for the XMWatchAndroid module.
let logger: Logger = Logger(subsystem: "com.doctordurant.xmwatch.android", category: "XMWatchAndroid")

/// The shared top-level view for the app, loaded from the platform-specific App delegates below.
///
/// The default implementation merely loads the `ContentView` for the app and logs a message.
/* SKIP @bridge */public struct XMWatchAndroidRootView : View {
    /* SKIP @bridge */public init() {
    }

    public var body: some View {
        ContentView()
            .task {
                logger.info("Skip app logs are viewable in the Xcode console for iOS; Android logs can be viewed in Studio or using adb logcat")
            }
    }
}

/// Global application delegate functions.
///
/// These functions can update a shared observable object to communicate app state changes to interested views.
/* SKIP @bridge */public final class XMWatchAndroidAppDelegate : Sendable {
    /* SKIP @bridge */public static let shared = XMWatchAndroidAppDelegate()

    private init() {
    }

    /* SKIP @bridge */public func onInit() {
        logger.debug("onInit")
    }

    /* SKIP @bridge */public func onLaunch() {
        logger.debug("onLaunch")
    }

    /* SKIP @bridge */public func onPhoneAutomation(_ request: String) {
        MainActor.assumeIsolated { ViewModel.shared.receivePhoneAutomation(request) }
    }

    /* SKIP @bridge */public func onOpenNowPlaying() {
        Task { @MainActor in ViewModel.shared.selectedTab = "player" }
    }
    /* SKIP @bridge */public func onBrowseLibrary(_ request: String, completion: @escaping @Sendable (String) -> Void) {
        Task { @MainActor in completion(await ControllerRadioCatalog.shared.browse(request)) }
    }
    /* SKIP @bridge */public func onPrepareLibrary(_ id: String, query: String, token: String) {
        Task { @MainActor in await ControllerRadioCatalog.shared.prepare(id, query: query, token: token) }
    }
    /* SKIP @bridge */public func onControllerArtwork(_ id: String, completion: @escaping @Sendable (String) -> Void) {
        Task { @MainActor in completion(await ControllerRadioCatalog.shared.artwork(id)) }
    }

    /* SKIP @bridge */public func onResume() {
        logger.debug("onResume")
    }

    /* SKIP @bridge */public func onPause() {
        logger.debug("onPause")
    }

    /* SKIP @bridge */public func onStop() {
        logger.debug("onStop")
    }

    /* SKIP @bridge */public func onDestroy() {
        logger.debug("onDestroy")
    }

    /* SKIP @bridge */public func onLowMemory() {
        logger.debug("onLowMemory")
    }
}
