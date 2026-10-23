import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RadioRegion: String, Codable, Sendable, CaseIterable {
    case us = "US", canada = "CA"
    public var host: String { self == .us ? "player.siriusxm.com" : "player.siriusxm.ca" }
}

public enum RadioAPIError: Error, Equatable, Sendable {
    case http(Int)
    case malformedResponse
    case authenticationRejected
    case provider(Int)
}

public enum RadioRequestStage: String, Sendable {
    case authentication, session, channels, configuration, metadata
    public var label: String {
        switch self {
        case .authentication: "Sign-in"
        case .session: "Session setup"
        case .channels: "Channel loading"
        case .configuration: "Stream configuration"
        case .metadata: "Now Playing"
        }
    }
}

public struct RadioRequestFailure: Error, Sendable {
    public let stage: RadioRequestStage
    public let reason: RadioAPIError
}

/// Session key material stays in memory. Never include it in diagnostics.
public struct RadioSession: Sendable {
    public let key: Data
    public let keyURLTemplate: String
    public let consumptionQuery: String
}

public struct RadioAccount: Codable, Equatable, Sendable {
    public let username: String
    public let identifier: String?
}

public struct RadioChannel: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let number: String
    public let name: String
    public let category: String
    public let artworkURL: URL?
}

/// Request construction deliberately preserves the existing client's wire format.
/// No credentials, cookies, or playback keys are written to preferences here.
public struct RadioAPI: Sendable {
    public let region: RadioRegion
    public let deviceID: String

    public init(region: RadioRegion, deviceID: String) {
        self.region = region
        self.deviceID = deviceID
    }

    public func loginRequest(username: String, password: String) throws -> URLRequest {
        try request(path: "/rest/v2/experience/modules/modify/authentication", body: [
            "moduleList": ["modules": [["moduleRequest": [
                "resultTemplate": "web",
                "deviceInfo": [
                    "osVersion": "Mac", "platform": "Web", "sxmAppVersion": "3.1802.10011.0",
                    "browser": "Safari", "browserVersion": "18.3", "appRegion": region.rawValue,
                    "deviceModel": "K2WebClient", "clientDeviceId": deviceID,
                    "player": "html5", "clientDeviceType": "web"
                ],
                "standardAuth": ["username": username, "password": password]
            ]]]]
        ])
    }

    public func channelsRequest() throws -> URLRequest {
        try request(path: "/rest/v4/experience/modules/get?type=2", body: [
            "moduleList": ["modules": [["moduleArea": "Discovery", "moduleType": "ChannelListing",
                "moduleRequest": ["resultTemplate": ""]]]]
        ])
    }

    public func sessionRequest(channelID: String = "siriushits1", now: Date = Date()) throws -> URLRequest {
        var components = URLComponents()
        let timestamp = String(Int64(now.timeIntervalSince1970 * 1000))
        components.queryItems = [URLQueryItem(name: "channelId", value: channelID),
            URLQueryItem(name: "contentType", value: "live"),
            URLQueryItem(name: "timestamp", value: timestamp),
            URLQueryItem(name: "cacheBuster", value: timestamp)]
        return try request(path: "/rest/v2/experience/modules/resume?" + (components.percentEncodedQuery ?? ""), body: [
            "moduleList": ["modules": [["moduleRequest": ["resultTemplate": "web", "deviceInfo": [
                "osVersion": "Mac", "platform": "Web", "clientDeviceType": "web",
                "sxmAppVersion": "3.1802.10011.0", "browser": "Safari", "browserVersion": "11.0.3",
                "appRegion": region.rawValue, "deviceModel": "K2WebClient", "player": "html5",
                "clientDeviceId": "null"
            ]]]]]
        ])
    }

    public static func session(data: Data, status: Int) throws -> RadioSession {
        let root = try envelope(data: data, status: status)
        guard let live = firstModule(root)?["liveChannelData"] as? [String: Any],
              let infos = live["customAudioInfos"] as? [[String: Any]],
              let chunks = infos.first?["chunks"] as? [String: Any],
              let rows = chunks["chunks"] as? [[String: Any]],
              let encoded = rows.first?["key"] as? String,
              let key = Data(base64Encoded: encoded), key.count == 16,
              let keyURL = rows.first?["keyUrl"] as? String, !keyURL.isEmpty,
              let consumption = live["hlsConsumptionInfo"] as? String else {
            throw RadioAPIError.malformedResponse
        }
        return RadioSession(key: key, keyURLTemplate: keyURL, consumptionQuery: consumption)
    }

    /// Fixed field names, counts and numeric codes only: no server text, account data,
    /// cookie values, URLs, request bodies or encryption keys.
    static func diagnostic(data: Data, status: Int, stage: RadioRequestStage) -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let root = json?["ModuleListResponse"] as? [String: Any]
        let list = root?["moduleList"] as? [String: Any]
        let modules = list?["modules"] as? [[String: Any]] ?? []
        let codes = (root?["messages"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? Int }
        let base = "stage=\(stage.rawValue) http=\(status) bytes=\(data.count) envelope=\(root != nil) modules=\(modules.count) codes=\(codes.prefix(8))"
        if stage == .channels, let root,
           let content = firstModule(root)?["contentData"] as? [String: Any],
           let listing = content["channelListing"] as? [String: Any],
           let channels = listing["channels"] as? [[String: Any]] {
            let images = channels.flatMap { ($0["images"] as? [String: Any])?["images"] as? [[String: Any]] ?? [] }
            let urls = images.compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
            let secure = urls.filter { $0.scheme == "https" }.count
            let insecure = urls.filter { $0.scheme == "http" }.count
            let trustedInsecure = urls.filter {
                $0.scheme == "http" && ($0.host?.lowercased() == "siriusxm.com" || $0.host?.lowercased().hasSuffix(".siriusxm.com") == true)
            }.count
            let preferred = images.filter { ($0["height"] as? Int) == 720 && ($0["name"] as? String) == "color channel logo (on dark)" }.count
            return base + " channels=\(channels.count) images=\(images.count) httpsImages=\(secure) httpImages=\(insecure) trustedHTTPImages=\(trustedInsecure) preferredImages=\(preferred)"
        }
        if stage == .metadata, let root, let live = firstModule(root)?["liveChannelData"] as? [String: Any] {
            let lists = live["markerLists"] as? [[String: Any]] ?? []
            let cuts = lists.first(where: { $0["layer"] as? String == "cut" })?["markers"] as? [[String: Any]] ?? []
            let open = cuts.filter { ($0["duration"] as? NSNumber)?.doubleValue == 0 }.count
            return base + " cuts=\(cuts.count) openCuts=\(open)"
        }
        return base
    }

    private func request(path: String, body: [String: Any]) throws -> URLRequest {
        guard let url = URL(string: "https://\(region.host)\(path)") else { throw RadioAPIError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public static func account(data: Data, response: HTTPURLResponse) throws -> RadioAccount {
        let root = try envelope(data: data, status: response.statusCode)
        let messages = root["messages"] as? [[String: Any]] ?? []
        if messages.contains(where: { ($0["code"] as? Int) == 101 || ($0["message"] as? String) == "Bad username/password" }) {
            throw RadioAPIError.authenticationRejected
        }
        guard let authentication = firstModule(root)?["authenticationData"] as? [String: Any],
              let username = authentication["username"] as? String, !username.isEmpty else {
            // An unknown error code or an empty message array is not proof of login.
            throw RadioAPIError.authenticationRejected
        }
        return RadioAccount(username: username, identifier: response.value(forHTTPHeaderField: "gupid"))
    }

    public static func channels(data: Data, status: Int) throws -> [RadioChannel] {
        let root = try envelope(data: data, status: status)
        guard let content = firstModule(root)?["contentData"] as? [String: Any],
              let listing = content["channelListing"] as? [String: Any],
              let rows = listing["channels"] as? [[String: Any]] else { throw RadioAPIError.malformedResponse }
        var seen = Set<String>()
        return rows.compactMap { row -> RadioChannel? in
            guard let id = row["channelId"] as? String, !id.isEmpty,
                  let name = row["name"] as? String, !name.isEmpty,
                  let number = row["channelNumber"] as? String,
                  seen.insert(id).inserted else { return nil }
            let categories = (row["categories"] as? [String: Any])?["categories"] as? [[String: Any]]
            let images = (row["images"] as? [String: Any])?["images"] as? [[String: Any]] ?? []
            let preferred = images.last { ($0["height"] as? Int) == 720 && ($0["name"] as? String) == "color channel logo (on dark)" }
            let artwork = (preferred?["url"] as? String).flatMap(channelArtworkURL)
            return RadioChannel(id: id, number: number, name: name,
                category: categories?.first?["name"] as? String ?? "Other",
                artworkURL: artwork)
        }.sorted {
            let lhs = Int($0.number) ?? Int.max, rhs = Int($1.number) ?? Int.max
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
    }

    /// Discovery still returns HTTP logos on SiriusXM's own image hosts. Fetch
    /// those over HTTPS without enabling arbitrary cleartext image requests.
    static func channelArtworkURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        if ["pri.art.prod.streaming.siriusxm.com", "sec.art.prod.streaming.siriusxm.com"].contains(host),
           components.path.hasPrefix("/images/"), ["http", "https"].contains(components.scheme?.lowercased() ?? "") {
            guard components.port == nil || components.port == 80 || components.port == 443 else { return nil }
            // The legacy Discovery art hostname has no matching TLS certificate.
            // SiriusXM serves the same public image path on this HTTPS endpoint.
            components.host = "albumart.siriusxm.com"
            components.scheme = "https"
            components.port = nil
        } else if components.scheme?.lowercased() == "http" {
            guard host == "siriusxm.com" || host.hasSuffix(".siriusxm.com"),
                  components.port == nil || components.port == 80 else { return nil }
            components.scheme = "https"
            components.port = nil
        }
        guard components.scheme?.lowercased() == "https" else { return nil }
        return components.url
    }

    static func envelope(data: Data, status: Int) throws -> [String: Any] {
        guard (200..<300).contains(status) else { throw RadioAPIError.http(status) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let root = json["ModuleListResponse"] as? [String: Any] else { throw RadioAPIError.malformedResponse }
        let codes = (root["messages"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? Int }
        if let failure = codes.first(where: { $0 != 100 }) {
            if failure == 101 { throw RadioAPIError.authenticationRejected }
            throw RadioAPIError.provider(failure)
        }
        return root
    }

    static func firstModule(_ root: [String: Any]) -> [String: Any]? {
        let list = root["moduleList"] as? [String: Any]
        let modules = list?["modules"] as? [[String: Any]]
        return modules?.first?["moduleResponse"] as? [String: Any]
    }
}

/// Owns an isolated cookie session; callers supply secure credential storage and UI.
public actor RadioClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let api: RadioAPI
    private let transport: Transport
    private let diagnostic: @Sendable (String) -> Void
    private var currentSession: RadioSession?
    private var cookies = RadioCookieJar()
    private var signedInAccount: RadioAccount?
    private var primaryRoot: URL?
    private var previewGeneration = UUID()

    public init(region: RadioRegion, deviceID: String, session: URLSession? = nil,
                transport: Transport? = nil,
                diagnostic: @escaping @Sendable (String) -> Void = { _ in }) {
        api = RadioAPI(region: region, deviceID: deviceID)
        let httpSession = session ?? URLSession(configuration: Self.configuration())
        self.transport = transport ?? { request in
            let (data, response) = try await httpSession.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw RadioAPIError.malformedResponse }
            return (data, response)
        }
        self.diagnostic = diagnostic
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }

    public func signIn(username: String, password: String) async throws -> RadioAccount {
        previewGeneration = UUID()
        currentSession = nil
        signedInAccount = nil
        cookies = RadioCookieJar()
        let account = try await perform(stage: .authentication,
            request: api.loginRequest(username: username, password: password)) { data, response in
                try RadioAPI.account(data: data, response: response)
            }
        // The existing Apple client establishes a live session before Discovery.
        // Authentication cookies alone are insufficient for the channel listing.
        currentSession = try await perform(stage: .session, request: api.sessionRequest()) { data, response in
            try RadioAPI.session(data: data, status: response.statusCode)
        }
        signedInAccount = account
        return account
    }

    public func channels() async throws -> [RadioChannel] {
        guard currentSession != nil else {
            throw RadioRequestFailure(stage: .session, reason: .authenticationRejected)
        }
        return try await perform(stage: .channels, request: api.channelsRequest()) { data, response in
            try RadioAPI.channels(data: data, status: response.statusCode)
        }
    }

    public func playbackPlan(channelID: String, bitrate: RadioBitrate = .high) async throws -> RadioPlaybackPlan {
        guard signedInAccount != nil else { throw RadioRequestFailure(stage: .session, reason: .authenticationRejected) }
        if primaryRoot == nil {
            primaryRoot = try await perform(stage: .configuration, request: api.configurationRequest()) { data, response in
                try RadioAPI.primaryHLSRoot(data: data, status: response.statusCode)
            }
        }
        let live = try await perform(stage: .session, request: api.sessionRequest(channelID: channelID)) { data, response in
            try RadioAPI.session(data: data, status: response.statusCode)
        }
        currentSession = live
        guard let root = primaryRoot,
              let url = try api.sessionRequest(channelID: channelID).url,
              let rawToken = cookies.value(named: "SXMAKTOKEN", for: url), rawToken.count > 45 else {
            throw RadioRequestFailure(stage: .session, reason: .malformedResponse)
        }
        // Preserve the working Apple client's SXMAKTOKEN extraction.
        let token = String(rawToken.dropFirst(3).prefix(43))
        return try RadioPlaybackPlan(session: live, primaryRoot: root, channelID: channelID, token: token, bitrate: bitrate)
    }

    public func nowPlaying(channelID: String, audibleDate: Date) async throws -> RadioNowPlaying {
        return try await perform(stage: .metadata, request: api.nowPlayingRequest(channelID: channelID)) { data, response in
            try RadioAPI.nowPlaying(data: data, status: response.statusCode, channelID: channelID, audibleDate: audibleDate)
        }
    }

    /// One authenticated bulk lookup; never retunes or overwrites the audible
    /// channel's separate nowPlaying timeline. Account changes retire old replies.
    public func channelPreviews() async throws -> [String: RadioChannelPreview] {
        guard currentSession != nil else { throw RadioRequestFailure(stage: .metadata, reason: .authenticationRejected) }
        return try await perform(stage: .metadata, request: api.channelPreviewsRequest(), generation: previewGeneration) { data, response in
            try RadioAPI.channelPreviews(data: data, status: response.statusCode)
        }
    }

    public func savedSession() throws -> String {
        guard let account = signedInAccount else { throw RadioAPIError.authenticationRejected }
        let snapshot = RadioSavedSession(version: 1, region: api.region, deviceID: api.deviceID,
            account: account, cookies: cookies.snapshot())
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 131_072, let json = String(data: data, encoding: .utf8) else { throw RadioAPIError.malformedResponse }
        return json
    }

    public func restoreSession(_ json: String) async throws -> RadioAccount {
        guard json.utf8.count <= 131_072, let data = json.data(using: .utf8) else { throw RadioAPIError.malformedResponse }
        let saved = try JSONDecoder().decode(RadioSavedSession.self, from: data)
        guard saved.version == 1, saved.region == api.region, saved.deviceID == api.deviceID else { throw RadioAPIError.malformedResponse }
        previewGeneration = UUID()
        cookies = try RadioCookieJar(snapshot: saved.cookies, region: api.region)
        currentSession = try await perform(stage: .session, request: api.sessionRequest()) { data, response in
            try RadioAPI.session(data: data, status: response.statusCode)
        }
        signedInAccount = saved.account
        return saved.account
    }

    private func perform<T: Sendable>(stage: RadioRequestStage, request: URLRequest, generation: UUID? = nil,
        decode: @Sendable (Data, HTTPURLResponse) throws -> T) async throws -> T {
        do {
            try Task.checkCancellation()
            var request = request
            request.httpShouldHandleCookies = false
            if let url = request.url { request.setValue(cookies.header(for: url), forHTTPHeaderField: "Cookie") }
            diagnostic("stage=\(stage.rawValue) sendingCookies=\(request.value(forHTTPHeaderField: "Cookie") != nil) storedCookies=\(cookies.count)")
            let (data, response) = try await transport(request)
            if let generation, generation != previewGeneration { throw CancellationError() }
            cookies.receive(response)
            try Task.checkCancellation()
            diagnostic(RadioAPI.diagnostic(data: data, status: response.statusCode, stage: stage))
            return try decode(data, response)
        } catch let error as RadioAPIError {
            throw RadioRequestFailure(stage: stage, reason: error)
        }
    }
}
