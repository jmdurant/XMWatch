import Foundation

/// A complete replacement snapshot, so pause/sign-out also clear stale watch metadata.
struct PhonePlaybackState: Codable, Equatable {
    var updatedAt: Date
    var channelID: String?
    var channelName: String?
    var channelNumber: String?
    var title: String?
    var artist: String?
    var artworkURL: String?
    var wantsPlayback: Bool
    var isPaused: Bool
    var isBuffering: Bool
    var isReconnecting: Bool

    var payload: [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return ["playback": data]
    }

    init?(payload: [String: Any]) {
        guard let data = payload["playback"] as? Data,
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = decoded
    }

    init(updatedAt: Date = Date(), channelID: String? = nil, channelName: String? = nil,
         channelNumber: String? = nil, title: String? = nil, artist: String? = nil,
         artworkURL: String? = nil, wantsPlayback: Bool = false, isPaused: Bool = true,
         isBuffering: Bool = false, isReconnecting: Bool = false) {
        self.updatedAt = updatedAt
        self.channelID = channelID
        self.channelName = channelName
        self.channelNumber = channelNumber
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.wantsPlayback = wantsPlayback
        self.isPaused = isPaused
        self.isBuffering = isBuffering
        self.isReconnecting = isReconnecting
    }
}

enum PhonePlaybackCommand: String {
    case refresh, play, pause, next, previous
}

/// Both immediate replies and background contexts can arrive out of order.
struct PhonePlaybackInbox {
    private(set) var state: PhonePlaybackState?

    mutating func accept(_ payload: [String: Any]) {
        guard let incoming = PhonePlaybackState(payload: payload),
              state == nil || incoming.updatedAt >= state!.updatedAt else { return }
        state = incoming
    }
}
