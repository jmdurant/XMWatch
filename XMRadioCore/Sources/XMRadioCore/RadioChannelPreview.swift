import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Discovery metadata keyed by RadioChannel.id. This describes the provider's
/// current channel listing, independently of delayed audible Now Playing data.
public struct RadioChannelPreview: Sendable, Equatable {
    public let title: String?
    public let artist: String?

    public init(title: String?, artist: String?) {
        self.title = title
        self.artist = artist
    }
}

extension RadioAPI {
    /// The existing Apple PDT endpoint returns all channel previews in one GET.
    public func channelPreviewsRequest(now: Date = Date()) throws -> URLRequest {
        let milliseconds = now.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite, milliseconds > Double(Int64.min) + 2048,
              milliseconds < Double(Int64.max) - 2048 else { throw RadioAPIError.malformedResponse }
        var url = URLComponents()
        url.scheme = "https"
        url.host = region.host
        url.path = "/rest/v2/experience/modules/get/discover-channel-list"
        url.queryItems = [URLQueryItem(name: "type", value: "2"),
            URLQueryItem(name: "batch-mode", value: "true"), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "request-option", value: "discover-channel-list-withpdt"),
            URLQueryItem(name: "result-template", value: "web"),
            URLQueryItem(name: "time", value: String(Int64(milliseconds)))]
        guard let address = url.url else { throw RadioAPIError.malformedResponse }
        var request = URLRequest(url: address)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Parse the actual discover-channel-list ModuleDetails nesting. Dated cuts
    /// select the latest started marker and honor its end (or the next start for
    /// open-ended cuts). Future cuts, promos and gaps never reuse an old song.
    /// Fully undated cut lists use their first marker, matching Apple's PDT
    /// convention; an invalid supplied date does not enable that fallback.
    /// Empty channel values deliberately clear stale UI metadata. Missing channel
    /// rows are omitted so a successful complete-map replacement also clears them.
    public static func channelPreviews(data: Data, status: Int, now: Date = Date()) throws -> [String: RadioChannelPreview] {
        guard data.count <= 8 * 1024 * 1024, now.timeIntervalSince1970.isFinite else { throw RadioAPIError.malformedResponse }
        let root = try envelope(data: data, status: status)
        if let code = root["status"] as? Int, code != 100 {
            throw code == 101 ? RadioAPIError.authenticationRejected : RadioAPIError.provider(code)
        }
        guard let details = firstModule(root)?["moduleDetails"] as? [String: Any],
              let live = details["liveChannelResponse"] as? [String: Any],
              let rows = live["liveChannelResponses"] as? [[String: Any]], rows.count <= 2048 else {
            throw RadioAPIError.malformedResponse
        }
        let formatter = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? {
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
                let seconds = number.doubleValue
                return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
            }
            guard let string = value as? String, string.utf8.count <= 128 else { return nil }
            if let number = Double(string), number.isFinite {
                return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
            }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        }
        func text(_ value: Any?) -> String? {
            guard let raw = value as? String else { return nil }
            let clean = String(String.UnicodeScalarView(raw.unicodeScalars.prefix(1024).filter {
                !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
            }.filter { $0.properties.generalCategory != .format }))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return clean.isEmpty ? nil : String(clean.prefix(256))
        }
        let empty = RadioChannelPreview(title: nil, artist: nil)
        var result: [String: RadioChannelPreview] = [:]
        for row in rows {
            guard let id = row["channelId"] as? String, !id.isEmpty, id.utf8.count <= 128,
                  id == id.trimmingCharacters(in: .whitespacesAndNewlines),
                  id.rangeOfCharacter(from: .controlCharacters) == nil, result[id] == nil else { continue }
            result[id] = empty
            let lists = (row["markerLists"] as? [[String: Any]] ?? []).prefix(32)
            let cutList = lists.first { ($0["layer"] as? String)?.lowercased() == "cut" }
                ?? lists.first { $0["layer"] == nil }
            let markers = Array((cutList?["markers"] as? [[String: Any]] ?? []).prefix(256))
            let hasTimestamp = markers.contains { ($0["timestamp"] as? [String: Any])?["absolute"] != nil }
            let marker: [String: Any]?
            if hasTimestamp {
                let dated = markers.compactMap { value -> ([String: Any], Date)? in
                    guard let time = date((value["timestamp"] as? [String: Any])?["absolute"]) else { return nil }
                    return (value, time)
                }
                if let current = dated.filter({ $0.1 <= now }).max(by: { $0.1 < $1.1 }) {
                    let duration: Double
                    if current.0["duration"] == nil || current.0["duration"] is NSNull { duration = 0 }
                    else if let value = current.0["duration"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { duration = value.doubleValue }
                    else { duration = .nan }
                    let next = dated.map(\.1).filter { $0 > current.1 }.min() ?? .distantFuture
                    let end = duration > 0 ? min(current.1.addingTimeInterval(duration), next) : next
                    marker = duration.isFinite && duration >= 0 && duration <= 604_800 && now < end ? current.0 : nil
                } else { marker = nil }
            } else { marker = markers.first }
            guard let cut = marker?["cut"] as? [String: Any],
                  cut["memberOfSpotBlock"] as? Bool != true,
                  cut["firstCutOfSpotBlock"] as? Bool != true,
                  text(cut["spotBlockId"]) == nil else { continue }
            let kind = (cut["cutContentType"] as? String)?.lowercased() ?? ""
            guard !["link", "exp", "promo", "advertisement", "commercial", "ad"].contains(kind) else { continue }
            let artists = cut["artists"] as? [[String: Any]]
            result[id] = RadioChannelPreview(title: text(cut["title"]), artist: text(artists?.first?["name"]))
        }
        return result
    }
}
