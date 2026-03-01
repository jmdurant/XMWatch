import Foundation

struct XMChannel: Identifiable, Hashable {
    let id: String           // channelId (e.g. "siriushits1")
    let number: String       // channel number (e.g. "2")
    let name: String         // display name (e.g. "Hits 1")
    let category: String     // category (e.g. "Pop")
    let mediumImageURL: String
    let largeImageURL: String

    // Current now-playing (updated from PDT)
    var artist: String?
    var song: String?
    var albumArtURL: String?
}
