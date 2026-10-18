import Foundation

/// The glasses control the iPhone's existing radio player. No second audio session
/// or SiriusXM connection is created by the display integration.
@MainActor
protocol MetaGlassesRadioPlayback: AnyObject {
    var glassesSnapshot: RadioGlassesSnapshot { get }
    func togglePlayback()
    func nextChannel() async
    func previousChannel() async
}

struct RadioGlassesSnapshot: Equatable {
    var channelID: String?
    var channelName = ""
    var channelNumber = ""
    var song: String?
    var artist: String?
    var wantsPlayback = false
    var isBuffering = false
    var isReconnecting = false

    var hasChannel: Bool { channelID != nil }
    var title: String { hasChannel ? (song?.nonempty ?? channelName) : "XMWatch" }
    var subtitle: String { hasChannel ? (artist?.nonempty ?? channelLine) : "Start a channel on your iPhone" }
    var channelLine: String { "Ch. \(channelNumber) · \(channelName)" }
    var playPauseLabel: String { wantsPlayback ? "Pause" : "Play" }
    var statusLine: String {
        guard hasChannel else { return "Nothing playing" }
        guard wantsPlayback else { return "Paused" }
        if isReconnecting { return "Reconnecting..." }
        if isBuffering { return "Tuning..." }
        return "Live"
    }
}

private extension String {
    var nonempty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

extension XMRadioService: MetaGlassesRadioPlayback {
    var glassesSnapshot: RadioGlassesSnapshot {
        RadioGlassesSnapshot(
            channelID: currentChannel?.id,
            channelName: currentChannel?.name ?? "",
            channelNumber: currentChannel?.number ?? "",
            song: nowPlayingSong,
            artist: nowPlayingArtist,
            wantsPlayback: userWantsPlayback,
            isBuffering: isBuffering,
            isReconnecting: isReconnecting
        )
    }
}
