import Foundation
import SkipFuse

#if SKIP
/// Opens the native glasses connection screen from the Swift settings view.
public final class MetaGlassesLink {
    public static func open() {
        MetaGlassesController.open(ProcessInfo.processInfo.androidContext)
    }
}
#endif

/// Only public playback metadata crosses the native UI boundary.
/* SKIP @bridge */public final class MetaPlaybackState: Sendable {
    /* SKIP @bridge */public static let shared = MetaPlaybackState()

    private init() {}

    /* SKIP @bridge */public func snapshot() -> String {
        MainActor.assumeIsolated {
            let model = ViewModel.shared
            let channel = model.currentChannel
            let available = channel != nil && model.account != nil
            let canChangeChannel = available && model.channels.count > 1 && model.channels.contains { $0.id == channel?.id }
            let status: String
            if model.account == nil { status = "Sign in to XMWatch on your phone." }
            else if let error = model.playbackError { status = error }
            else if model.isBuffering { status = "Connecting…" }
            else if channel == nil { status = "Choose a channel in XMWatch." }
            else if model.userWantsPlayback { status = "Live radio" }
            else { status = "Paused" }
            let state: [String: Any] = [
                "title": model.nowPlayingTitle ?? channel?.name ?? "XMWatch",
                "subtitle": model.nowPlayingArtist ?? "",
                "detail": channel.map { "Channel \($0.number) · \($0.name)" } ?? "SiriusXM radio",
                "status": status,
                "playing": model.userWantsPlayback,
                "buffering": model.isBuffering,
                "positionMS": Int64(0), "durationMS": Int64(0),
                "canPlayPause": available,
                "canPrevious": canChangeChannel, "canNext": canChangeChannel,
                "canSeek": false, "canChangeRate": false,
                "rate": 1.0, "seekBackSeconds": 0, "seekForwardSeconds": 0
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: state) else { return "{}" }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
