import Foundation

public enum RadioBitrate: String, Codable, Sendable {
    case standard = "64k", high = "256k"
}

/// Private transport instructions. Only sanitized channel metadata belongs in a
/// system media session; this plan includes authentication and key material.
public struct RadioPlaybackPlan: Codable, Sendable {
    public let playlistURL: URL
    public let segmentBaseURL: URL
    public let authorizationQuery: String
    public let key: Data
    public let channelID: String

    public init(session: RadioSession, primaryRoot: URL, channelID: String,
                token: String, bitrate: RadioBitrate = .high) throws {
        guard !channelID.isEmpty, channelID.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }), primaryRoot.scheme == "https", primaryRoot.host != nil,
            session.key.count == 16, !token.isEmpty else { throw RadioAPIError.malformedResponse }
        let root = primaryRoot.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let filename = "\(channelID)_\(bitrate.rawValue)_medium_v3.m3u8"
        let source = session.keyURLTemplate.replacingOccurrences(of: "%Live_Primary_HLS%", with: root)
            .replacingOccurrences(of: "32k", with: bitrate.rawValue)
            .replacingOccurrences(of: "key/1", with: filename)
        var suffix = session.consumptionQuery
        if !suffix.hasPrefix("?") { suffix = "?" + suffix.trimmingCharacters(in: CharacterSet(charactersIn: "&")) }
        var tokenQuery = URLComponents()
        tokenQuery.queryItems = [URLQueryItem(name: "token", value: token)]
        suffix += (suffix == "?" ? "" : "&") + (tokenQuery.percentEncodedQuery ?? "")
        guard let playlist = URL(string: source + suffix), playlist.scheme == "https",
              playlist.host == primaryRoot.host,
              let segments = URL(string: root + "/AAC_Data/\(channelID)/HLS_\(channelID)_\(bitrate.rawValue)_v3/") else {
            throw RadioAPIError.malformedResponse
        }
        self.playlistURL = playlist
        self.segmentBaseURL = segments
        self.authorizationQuery = suffix
        self.key = session.key
        self.channelID = channelID
    }
}

extension RadioAPI {
    public func configurationRequest() throws -> URLRequest {
        // Keep the existing provider configuration endpoint and region selection.
        guard let url = URL(string: "https://\(region.host)/rest/v2/experience/modules/get/configuration?result-template=html5&app-region=\(region.rawValue)") else {
            throw RadioAPIError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        return request
    }

    public static func primaryHLSRoot(data: Data, status: Int) throws -> URL {
        let envelope = try envelope(data: data, status: status)
        guard let configuration = firstModule(envelope)?["configuration"] as? [String: Any],
              let components = configuration["components"] as? [[String: Any]],
              let relative = components.first(where: { $0["name"] as? String == "relativeUrls" }) else {
            throw RadioAPIError.malformedResponse
        }
        // The provider returns settings as an array; older cached configurations
        // represented it as a dictionary. Handle both observed shapes explicitly.
        let settings = (relative["settings"] as? [[String: Any]]) ?? (relative["settings"] as? [String: Any]).map { [$0] } ?? []
        let rows = settings.flatMap { entry -> [[String: Any]] in
            if let rows = entry["relativeUrls"] as? [[String: Any]] { return rows }
            return (entry["relativeUrls"] as? [[[String: Any]]])?.flatMap { $0 } ?? []
        }
        guard let value = rows.first(where: { $0["name"] as? String == "Live_Primary_HLS" })?["url"] as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else {
            throw RadioAPIError.malformedResponse
        }
        return url
    }
}

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
