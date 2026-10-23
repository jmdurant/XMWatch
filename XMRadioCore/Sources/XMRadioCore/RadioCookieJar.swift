import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Actor-owned, in-memory cookies. Explicit scoping avoids differences between
/// Darwin and FoundationNetworking's automatic cookie stores.
struct RadioCookieJar {
    private var cookies: [HTTPCookie] = []
    init() {}
    init(snapshot: [RadioSavedCookie], region: RadioRegion) throws {
        guard snapshot.count <= 256 else { throw RadioAPIError.malformedResponse }
        let allowed = [region.host, "." + region.host, region == .us ? "siriusxm.com" : "siriusxm.ca",
            region == .us ? ".siriusxm.com" : ".siriusxm.ca"]
        for saved in snapshot {
            guard allowed.contains(saved.domain), saved.path.hasPrefix("/"),
                  !saved.name.contains(where: { $0 == "\r" || $0 == "\n" || $0 == ";" }),
                  !saved.value.contains(where: { $0 == "\r" || $0 == "\n" || $0 == ";" }) else {
                throw RadioAPIError.malformedResponse
            }
            var properties: [HTTPCookiePropertyKey: Any] = [.name: saved.name, .value: saved.value,
                .domain: saved.domain, .path: saved.path, .secure: saved.secure ? "TRUE" : "FALSE"]
            if let expiry = saved.expiry { properties[.expires] = expiry }
            guard let cookie = HTTPCookie(properties: properties) else { throw RadioAPIError.malformedResponse }
            if cookie.expiresDate.map({ $0 > Date() }) ?? true { cookies.append(cookie) }
        }
    }
    func snapshot() -> [RadioSavedCookie] {
        cookies.map { RadioSavedCookie(name: $0.name, value: $0.value, domain: $0.domain,
            path: $0.path, secure: $0.isSecure, expiry: $0.expiresDate) }
    }
    func value(named name: String, for url: URL) -> String? {
        // Reuse the same URL selection rules as the wire header.
        guard let header = header(for: url) else { return nil }
        return header.components(separatedBy: "; ").first { $0.hasPrefix(name + "=") }
            .map { String($0.dropFirst(name.count + 1)) }
    }

    mutating func receive(_ response: HTTPURLResponse, now: Date = Date()) {
        guard let url = response.url, let host = url.host?.lowercased() else { return }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let name = field.key as? String, let value = field.value as? String { result[name] = value }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            let domain = cookie.domain.lowercased()
            // Only the selected SiriusXM host or its own parent domain may set cookies.
            let allowed = [host, "." + host, "siriusxm.com", ".siriusxm.com", "siriusxm.ca", ".siriusxm.ca"]
            guard allowed.contains(domain), Self.matches(host: host, domain: domain) else { continue }
            cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            if cookie.expiresDate.map({ $0 > now }) ?? true { cookies.append(cookie) }
        }
        cookies.removeAll { $0.expiresDate.map { $0 <= now } ?? false }
    }

    func header(for url: URL, now: Date = Date()) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let applicable = cookies.filter { cookie in
            Self.matches(host: host, domain: cookie.domain.lowercased()) &&
            (!cookie.isSecure || url.scheme == "https") &&
            (cookie.expiresDate.map { $0 > now } ?? true) &&
            (path == cookie.path || (path.hasPrefix(cookie.path) &&
                (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/"))))
        }.sorted { $0.path.count > $1.path.count }
        return HTTPCookie.requestHeaderFields(with: applicable)["Cookie"]
    }

    var count: Int { cookies.count }

    private static func matches(host: String, domain: String) -> Bool {
        if domain.hasPrefix(".") { return host == domain.dropFirst() || host.hasSuffix(domain) }
        return host == domain
    }
}

struct RadioSavedCookie: Codable, Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let secure: Bool
    let expiry: Date?
}

struct RadioSavedSession: Codable, Sendable {
    let version: Int
    let region: RadioRegion
    let deviceID: String
    let account: RadioAccount
    let cookies: [RadioSavedCookie]
}
