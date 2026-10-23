import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import XMRadioCore

private func envelope(_ module: [String: Any], messages: [[String: Any]] = []) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["ModuleListResponse": [
        "messages": messages, "moduleList": ["modules": [["moduleResponse": module]]]
    ]])
}
private func response(_ status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://player.siriusxm.ca/login")!, statusCode: status,
                    httpVersion: nil, headerFields: ["GuPiD": "fixture-account"])!
}

@Test(arguments: RadioRegion.allCases)
func regionAndCredentials(region: RadioRegion) throws {
    let api = RadioAPI(region: region, deviceID: "fixture-device")
    let request = try api.loginRequest(username: "name+test@example.com", password: "quote\"&password")
    #expect(request.url?.host == region.host)
    #expect(request.url?.scheme == "https")
    #expect(request.httpMethod == "POST")
    #expect(request.url?.query == nil)
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let list = try #require(json["moduleList"] as? [String: Any])
    let modules = try #require(list["modules"] as? [[String: Any]])
    let module = try #require(modules.first?["moduleRequest"] as? [String: Any])
    let device = try #require(module["deviceInfo"] as? [String: String])
    #expect(device["appRegion"] == region.rawValue)
    #expect(device["clientDeviceId"] == "fixture-device")
    let credentials = try #require(module["standardAuth"] as? [String: String])
    #expect(credentials["password"] == "quote\"&password")
    #expect(try api.channelsRequest().url?.host == region.host)
}

@Test func loginRequiresAuthenticationData() throws {
    let empty = try envelope([:])
    #expect(throws: RadioAPIError.authenticationRejected) { try RadioAPI.account(data: empty, response: response()) }
    let unexpected = try envelope([:], messages: [["code": 999, "message": "Unknown failure"]])
    #expect(throws: RadioAPIError.provider(999)) { try RadioAPI.account(data: unexpected, response: response()) }
    let valid = try envelope(["authenticationData": ["username": "test@example.com"]])
    let account = try RadioAPI.account(data: valid, response: response())
    #expect(account.username == "test@example.com")
    #expect(account.identifier == "fixture-account")
    #expect(throws: RadioAPIError.http(403)) { try RadioAPI.account(data: valid, response: response(403)) }
    let rejected = try envelope(["authenticationData": ["username": "test@example.com"]], messages: [["code": 101]])
    #expect(throws: RadioAPIError.authenticationRejected) { try RadioAPI.account(data: rejected, response: response()) }
}

@Test func catalogPreservesChannelsWithoutImagesAndSortsNumerically() throws {
    let rows: [[String: Any]] = [
        ["channelId": "ten", "channelNumber": "10", "name": "Ten"],
        ["channelId": "two", "channelNumber": "2", "name": "Two", "categories": ["categories": [["name": "Pop"]]],
         "images": ["images": [["height": 720, "name": "color channel logo (on dark)", "url": "https://example.com/logo.png"]]]],
        ["channelId": "two", "channelNumber": "2", "name": "Duplicate"],
        ["channelId": "invalid"],
        ["channelId": "local", "channelNumber": "3", "name": "Unsafe art", "images": ["images": [
            ["height": 720, "name": "color channel logo (on dark)", "url": "file:///private/art.png"]]]]
    ]
    let data = try envelope(["contentData": ["channelListing": ["channels": rows]]])
    let channels = try RadioAPI.channels(data: data, status: 200)
    #expect(channels.map(\.id) == ["two", "local", "ten"])
    #expect(channels.first?.category == "Pop")
    #expect(channels.first?.artworkURL?.host == "example.com")
    #expect(channels[1].artworkURL == nil)
    #expect(channels.last?.category == "Other")
    #expect(throws: RadioAPIError.http(401)) { try RadioAPI.channels(data: data, status: 401) }
}

@Test func emptyAndMalformedCatalogAreDifferent() throws {
    let empty = try envelope(["contentData": ["channelListing": ["channels": []]]])
    #expect(try RadioAPI.channels(data: empty, status: 200).isEmpty)
    let malformed = try envelope([:])
    #expect(throws: RadioAPIError.malformedResponse) { try RadioAPI.channels(data: malformed, status: 200) }
}

private func sessionFixture(key: Data = Data(repeating: 1, count: 16)) throws -> Data {
    try envelope(["liveChannelData": [
        "customAudioInfos": [["chunks": ["chunks": [["key": key.base64EncodedString(),
            "keyUrl": "%Live_Primary_HLS%/key/1"]]]]],
        "hlsConsumptionInfo": "?fixture=session"
    ]])
}

@Test func sessionRequestAndKeyValidation() throws {
    let api = RadioAPI(region: .canada, deviceID: "test")
    let request = try api.sessionRequest(channelID: "test&channel", now: Date(timeIntervalSince1970: 123))
    let url = try #require(request.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "player.siriusxm.ca")
    #expect(components.queryItems?.first { $0.name == "channelId" }?.value == "test&channel")
    #expect(components.queryItems?.first { $0.name == "timestamp" }?.value == "123000")
    let valid = try sessionFixture()
    #expect(try RadioAPI.session(data: valid, status: 200).key.count == 16)
    let invalid = try sessionFixture(key: Data(repeating: 1, count: 15))
    #expect(throws: RadioAPIError.malformedResponse) { try RadioAPI.session(data: invalid, status: 200) }
    let diagnostic = RadioAPI.diagnostic(data: valid, status: 200, stage: .session)
    #expect(!diagnostic.contains("fixture=session"))
    #expect(!diagnostic.contains(Data(repeating: 1, count: 16).base64EncodedString()))
}

private actor LoginFlowFixture {
    var paths: [String] = []
    let rejectSession: Bool
    init(rejectSession: Bool = false) { self.rejectSession = rejectSession }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        paths.append(url.path)
        let data: Data
        var headers: [String: String] = [:]
        switch url.path {
        case "/rest/v2/experience/modules/modify/authentication":
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            headers["Set-Cookie"] = "AUTH=login-fixture; Path=/; Secure; HttpOnly"
            data = try envelope(["authenticationData": ["username": "fixture"]])
        case "/rest/v2/experience/modules/resume":
            #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("AUTH=login-fixture") == true || request.value(forHTTPHeaderField: "Cookie")?.contains("AUTH=renewed-fixture") == true)
            headers["Set-Cookie"] = "AUTH=renewed-fixture; Path=/; Secure; HttpOnly, V2ONLY=fixture; Path=/rest/v2; Secure"
            data = rejectSession ? try envelope([:]) : try sessionFixture()
        case "/rest/v4/experience/modules/get":
            #expect(request.value(forHTTPHeaderField: "Cookie") == "AUTH=renewed-fixture")
            guard paths.dropLast().last == "/rest/v2/experience/modules/resume" else {
                throw RadioAPIError.authenticationRejected
            }
            data = try envelope(["contentData": ["channelListing": ["channels": [
                ["channelId": "hits", "channelNumber": "2", "name": "Hits"]
            ]]]])
        default: throw RadioAPIError.malformedResponse
        }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}

@Test func authenticationEstablishesSessionBeforeDiscovery() async throws {
    let fixture = LoginFlowFixture()
    let client = RadioClient(region: .us, deviceID: "fixture", transport: { try await fixture.send($0) })
    let account = try await client.signIn(username: "fixture", password: "fixture")
    #expect(account.username == "fixture")
    let channels = try await client.channels()
    #expect(channels.map(\.id) == ["hits"])
    #expect(await fixture.paths == ["/rest/v2/experience/modules/modify/authentication",
        "/rest/v2/experience/modules/resume", "/rest/v4/experience/modules/get"])
}

@Test func failedSessionPreventsDiscoveryAndIdentifiesStage() async throws {
    let fixture = LoginFlowFixture(rejectSession: true)
    let client = RadioClient(region: .us, deviceID: "fixture", transport: { try await fixture.send($0) })
    do {
        _ = try await client.signIn(username: "fixture", password: "fixture")
        Issue.record("Invalid session was accepted")
    } catch let failure as RadioRequestFailure {
        #expect(failure.stage == .session)
        #expect(failure.reason == .malformedResponse)
    }
    do {
        _ = try await client.channels()
        Issue.record("Discovery ran without a session")
    } catch let failure as RadioRequestFailure {
        #expect(failure.stage == .session)
    }
    #expect(await fixture.paths.count == 2)
}

@Test func providerErrorsAreNotMalformedCatalogs() throws {
    let data = try envelope([:], messages: [["code": 208]])
    #expect(throws: RadioAPIError.provider(208)) { try RadioAPI.channels(data: data, status: 200) }
}

@Test func cookieScopeRenewalExpiryAndRegionIsolation() throws {
    var jar = RadioCookieJar()
    let origin = URL(string: "https://player.siriusxm.com/rest/v2/auth")!
    let now = Date(timeIntervalSince1970: 1_000)
    func receive(_ value: String) {
        jar.receive(HTTPURLResponse(url: origin, statusCode: 200, httpVersion: nil,
            headerFields: ["Set-Cookie": value])!, now: now)
    }
    receive("ROOT=fixture; Path=/; Secure; HttpOnly, SCOPED=fixture; Path=/rest/v2; Secure")
    #expect(jar.header(for: URL(string: "https://player.siriusxm.com/rest/v4/get")!, now: now) == "ROOT=fixture")
    #expect(jar.header(for: URL(string: "https://player.siriusxm.com/rest/v20/get")!, now: now) == "ROOT=fixture")
    #expect(jar.header(for: URL(string: "https://player.siriusxm.com/rest/v2/get")!, now: now)?.contains("SCOPED=fixture") == true)
    #expect(jar.header(for: URL(string: "http://player.siriusxm.com/")!, now: now) == nil)
    #expect(jar.header(for: URL(string: "https://player.siriusxm.ca/")!, now: now) == nil)
    #expect(jar.header(for: URL(string: "https://player.siriusxm.com.attacker.invalid/")!, now: now) == nil)
    receive("ROOT=renewed; Path=/; Secure")
    #expect(jar.header(for: origin, now: now)?.contains("ROOT=fixture") == false)
    receive("ROOT=; Path=/; Secure; Expires=Thu, 01 Jan 1970 00:00:00 GMT")
    #expect(jar.header(for: URL(string: "https://player.siriusxm.com/")!, now: now) == nil)
    receive("BAD=fixture; Domain=.com; Path=/")
    #expect(jar.header(for: origin, now: now)?.contains("BAD=") == false)
}

@Test func realURLSessionCarriesCookiesAcrossLoginResumeAndDiscovery() async throws {
    let configuration = RadioClient.configuration()
    #expect(configuration.httpCookieStorage == nil)
    #expect(!configuration.httpShouldSetCookies)
    configuration.protocolClasses = [RadioCookieProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = RadioClient(region: .us, deviceID: "fixture", session: session)
    _ = try await client.signIn(username: "fixture", password: "fixture")
    let channels = try await client.channels()
    #expect(channels.map(\.id) == ["fixture"])
}

private final class RadioCookieProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "player.siriusxm.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = request.url!
            let cookie = request.value(forHTTPHeaderField: "Cookie")
            var headers: [String: String] = [:]
            let data: Data
            if url.path.hasSuffix("/authentication") && cookie == nil {
                headers["Set-Cookie"] = "AUTH=fixture; Path=/; Secure, SCOPED=old; Path=/rest/v2; Secure"
                data = try envelope(["authenticationData": ["username": "fixture"]])
            } else if url.path.hasSuffix("/resume") && cookie?.contains("AUTH=fixture") == true {
                headers["Set-Cookie"] = "AUTH=new; Path=/; Secure, TOKEN=fixture; Path=/; Secure"
                data = try sessionFixture()
            } else if url.path.hasSuffix("/get") && cookie?.contains("AUTH=new") == true &&
                        cookie?.contains("TOKEN=fixture") == true && cookie?.contains("SCOPED=") == false {
                data = try envelope(["contentData": ["channelListing": ["channels": [
                    ["channelId": "fixture", "channelNumber": "2", "name": "Fixture"]
                ]]]])
            } else {
                data = try envelope([:], messages: [["code": 208]])
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Test func savedSessionRestoresWithoutPasswordAndRevalidatesWithProvider() async throws {
    let fixture = LoginFlowFixture()
    let client = RadioClient(region: .us, deviceID: "fixture", transport: { try await fixture.send($0) })
    _ = try await client.signIn(username: "fixture", password: "password-never-persisted")
    let saved = try await client.savedSession()
    #expect(!saved.contains("password-never-persisted"))
    #expect(!saved.contains("keyURLTemplate"))
    let restored = RadioClient(region: .us, deviceID: "fixture", transport: { try await fixture.send($0) })
    _ = try await restored.restoreSession(saved)
    #expect(try await restored.channels().count == 1)
    #expect(await fixture.paths.filter { $0.hasSuffix("authentication") }.count == 1)
}

@Test func discoveryLogosUpgradeTrustedHTTPAndRejectLookalikesAndCredentials() throws {
    let logo = "http://pri.art.prod.streaming.siriusxm.com/images/chan/67/fixture.png"
    let rows: [[String: Any]] = [["channelId": "hits1", "channelNumber": "2", "name": "Hits 1",
        "images": ["images": [["height": 720, "name": "color channel logo (on dark)", "url": logo]]]]]
    let data = try envelope(["contentData": ["channelListing": ["channels": rows]]])
    let channels = try RadioAPI.channels(data: data, status: 200)
    #expect(channels.first?.artworkURL?.absoluteString == "https://albumart.siriusxm.com/images/chan/67/fixture.png")
    #expect(RadioAPI.channelArtworkURL("https://sec.art.prod.streaming.siriusxm.com/images/chan/67/fixture.png")?.host == "albumart.siriusxm.com")
    #expect(RadioAPI.channelArtworkURL("http://siriusxm.com:80/logo.png")?.absoluteString == "https://siriusxm.com/logo.png")
    for invalid in ["http://siriusxm.com.evil.example/logo.png", "http://evil-siriusxm.com/logo.png",
                    "http://example.com/logo.png", "https://user:secret@www.siriusxm.com/logo.png",
                    "http://www.siriusxm.com:8080/logo.png", "file:///logo.png"] {
        #expect(RadioAPI.channelArtworkURL(invalid) == nil)
    }
}
