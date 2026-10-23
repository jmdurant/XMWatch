import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RadioNowPlaying: Equatable, Sendable {
    public let title: String?
    public let artist: String?
    public let artworkURL: URL?
    public let nextPollSeconds: Double
}

extension RadioAPI {
    public func nowPlayingRequest(channelID: String, now: Date = Date()) throws -> URLRequest {
        var url = URLComponents()
        url.scheme = "https"; url.host = region.host
        url.path = "/rest/v4/experience/modules/tune/now-playing-live"
        url.queryItems = [URLQueryItem(name: "channelId", value: channelID),
            URLQueryItem(name: "hls_output_mode", value: "none"),
            URLQueryItem(name: "marker_mode", value: "all_separate_cue_points"),
            URLQueryItem(name: "ccRequestType", value: "AUDIO_VIDEO"),
            URLQueryItem(name: "result-template", value: "web"),
            URLQueryItem(name: "time", value: String(Int64(now.timeIntervalSince1970 * 1000)))]
        guard let address = url.url else { throw RadioAPIError.malformedResponse }
        var request = URLRequest(url: address)
        request.timeoutInterval = 8; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Select the marker covering the audible timeline, not the newest announced
    /// song. Links/promos and gaps deliberately clear stale song information.
    public static func nowPlaying(data: Data, status: Int, channelID: String, audibleDate: Date) throws -> RadioNowPlaying {
        let root = try envelope(data: data, status: status)
        guard let live = firstModule(root)?["liveChannelData"] as? [String: Any],
              (live["channelId"] as? String).map({ $0 == channelID }) ?? true else {
            throw RadioAPIError.malformedResponse
        }
        let lists = live["markerLists"] as? [[String: Any]] ?? []
        let markers = lists.first(where: { $0["layer"] as? String == "cut" })?["markers"] as? [[String: Any]] ?? []
        let formatter = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? {
            if let value = value as? NSNumber, value.doubleValue.isFinite {
                let time = value.doubleValue
                return Date(timeIntervalSince1970: time > 100_000_000_000 ? time / 1000 : time)
            }
            guard let value = value as? String else { return nil }
            if let time = Double(value), time.isFinite { return Date(timeIntervalSince1970: time > 100_000_000_000 ? time / 1000 : time) }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let result = formatter.date(from: value) { return result }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }
        let dated = markers.compactMap { marker -> ([String: Any], Date, Double)? in
            let timestamp = marker["timestamp"] as? [String: Any]
            guard let start = date(timestamp?["absolute"]), let duration = marker["duration"] as? Double,
                  duration.isFinite, duration >= 0 else { return nil }
            return (marker, start, duration)
        }
        let active = dated.filter { candidate in
            guard candidate.1 <= audibleDate else { return false }
            let next = dated.map { $0.1 }.filter { $0 > candidate.1 }.min()
            // A live cut has no final duration until it ends. It remains current
            // until the next cut starts; a later completed cut still creates a gap.
            let end = candidate.2 > 0 ? candidate.1.addingTimeInterval(candidate.2) : (next ?? .distantFuture)
            return audibleDate < end
        }.max { $0.1 < $1.1 }
        let cut = active?.0["cut"] as? [String: Any]
        func text(_ value: Any?) -> String? {
            guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        let artists = cut?["artists"] as? [[String: Any]]
        let album = cut?["album"] as? [String: Any]
        let arts = album?["creativeArts"] as? [[String: Any]] ?? []
        let art = arts.last(where: { ($0["size"] as? String) == "MEDIUM" }) ?? arts.first
        let address = text(art?["relativeUrl"]) ?? text(art?["url"])
        let artwork = address.flatMap { URL(string: $0.replacingOccurrences(of: "%Album_Art%", with: "https://albumart.siriusxm.com")) }
        var boundaries = dated.map { $0.1 }.filter { $0 > audibleDate }
        if let active, active.2 > 0 { boundaries.append(active.1.addingTimeInterval(active.2)) }
        let next = boundaries.min()?.timeIntervalSince(audibleDate) ?? 8
        return RadioNowPlaying(title: text(cut?["title"]), artist: text(artists?.first?["name"]),
            artworkURL: artwork?.scheme == "https" ? artwork : nil,
            nextPollSeconds: active == nil ? 2 : min(8, max(1, next)))
    }
}
