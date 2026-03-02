import AVFoundation
import Foundation
import os
import StarPlayrRadioKit

private let log = Logger(subsystem: "com.starplayrx.xmwatch.watchos", category: "RadioService")

@MainActor @Observable
final class XMRadioService {
    enum AuthStatus: Equatable {
        case signedOut
        case signingIn
        case ready
    }

    private(set) var status: AuthStatus = .signedOut
    private(set) var channels: [XMChannel] = []
    private(set) var categories: [String] = []
    var currentChannel: XMChannel?
    private(set) var nowPlayingArtist: String?
    private(set) var nowPlayingSong: String?
    private(set) var nowPlayingArtURL: String?
    private(set) var errorMessage: String?
    // Debug text visible in UI
    var debugLog: String = ""

    // Player state — lives here so it survives tab switches
    private(set) var playerController: WatchAVPlayerController?
    private(set) var nowPlayingManager: WatchNowPlayingManager?
    private(set) var isPaused: Bool = true
    private var proxyServer = XMHLSProxyServer.shared
    private var pdtTimer: Task<Void, Never>?
    private var tokenTimer: Task<Void, Never>?

    var favoriteChannelNumbers: Set<String> {
        didSet { saveFavorites() }
    }

    private var tokenRefreshTime: Int = 0
    private var pdtCache: [String: Any] = [:]

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "xm_favorites") ?? []
        favoriteChannelNumbers = Set(saved)

        let autoGupid = UserDefaults.standard.string(forKey: "gupid") ?? ""
        let autoChannels = UserDefaults.standard.dictionary(forKey: "channels") ?? [:]
        if !autoGupid.isEmpty && autoChannels.count > 1 {
            status = .ready
        }
    }

    // MARK: - Debug helper
    private func dbg(_ msg: String) {
        debugLog += "\n" + msg
        log.info("\(msg)")
    }

    // MARK: - Async Session (replaces Session() to avoid semaphore deadlocks)
    private func asyncSession(channelId: String) async -> Bool {
        let timeInterval = Date().timeIntervalSince1970
        let intTime = Int(timeInterval * 1000)
        let time = String(intTime)

        let endpoint = "\(http)\(root)/resume?channelId=\(channelId)&contentType=live&timestamp=\(time)&cacheBuster=\(time)"
        let request: [String: Any] = [
            "moduleList": [
                "modules": [
                    ["moduleRequest": [
                        "resultTemplate": "web",
                        "deviceInfo": [
                            "osVersion": "Mac",
                            "platform": "Web",
                            "clientDeviceType": "web",
                            "sxmAppVersion": "3.1802.10011.0",
                            "browser": "Safari",
                            "browserVersion": "11.0.3",
                            "appRegion": appRegion,
                            "deviceModel": "K2WebClient",
                            "player": "html5",
                            "clientDeviceId": "null"
                        ]
                    ]]
                ]
            ]
        ]

        guard let result = await asyncPost(request: request, endpoint: endpoint) else {
            dbg("session POST failed")
            return false
        }

        dbg("session HTTP \(result.response.statusCode)")

        guard result.response.statusCode == 200 else { return false }

        // Extract SXMAKTOKEN from cookies
        if let fields = result.response.allHeaderFields as? [String: String],
           let url = result.response.url {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            HTTPCookieStorage.shared.setCookies(cookies, for: url, mainDocumentURL: URL(string: http + root))

            for cookie in cookies where cookie.name == "SXMAKTOKEN" {
                let t = cookie.value
                if t.count > 44 {
                    let startIndex = t.index(t.startIndex, offsetBy: 3)
                    let endIndex = t.index(t.startIndex, offsetBy: 45)
                    userX.token = String(t[startIndex...endIndex])
                    UserDefaults.standard.set(userX.token, forKey: "token")
                    dbg("token set: \(userX.token.prefix(8))...")
                }
            }
        }

        // Extract encryption keys
        let dict = result.data as NSDictionary
        if let s = dict.value(forKeyPath: "ModuleListResponse.moduleList.modules") as? NSArray,
           let x = s.firstObject as? NSDictionary {
            if let customAudioInfos = x.value(forKeyPath: "moduleResponse.liveChannelData.customAudioInfos") as? NSArray,
               let c = customAudioInfos.firstObject as? NSDictionary,
               let chunk = c.value(forKeyPath: "chunks.chunks") as? NSArray,
               let d = chunk.firstObject as? NSDictionary,
               let key = d.value(forKeyPath: "key") as? String,
               let keyurl = d.value(forKeyPath: "keyUrl") as? String,
               let consumer = x.value(forKeyPath: "moduleResponse.liveChannelData.hlsConsumptionInfo") as? String {

                userX.key = key
                userX.keyurl = keyurl
                userX.consumer = consumer

                UserDefaults.standard.set(key, forKey: "key")
                UserDefaults.standard.set(keyurl, forKey: "keyurl")
                UserDefaults.standard.set(consumer, forKey: "consumer")
                dbg("keys set")
            }
        }

        return true
    }

    // MARK: - Async HTTP POST (replaces PostSync to avoid semaphore deadlocks)
    private func asyncPost(request: [String: Any], endpoint: String) async -> (data: [String: Any], response: HTTPURLResponse)? {
        guard let url = URL(string: endpoint) else {
            dbg("POST: bad URL")
            return nil
        }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try? JSONSerialization.data(withJSONObject: request, options: .prettyPrinted)
        urlReq.timeoutInterval = 60
        urlReq.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: urlReq)
            guard let httpResp = response as? HTTPURLResponse else {
                dbg("POST: not HTTPURLResponse")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                dbg("POST: JSON parse failed")
                return nil
            }
            return (data: json, response: httpResp)
        } catch {
            dbg("POST error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Configuration

    func configure(region: String) async {
        dbg("configure: \(region)")
        // preflightConfig sets globals and is synchronous — run off main
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                preflightConfig(location: region)
                cont.resume()
            }
        }

        let autoGupid = UserDefaults.standard.string(forKey: "gupid") ?? ""
        let autoChannels = UserDefaults.standard.dictionary(forKey: "channels") ?? [:]
        dbg("configure: gupid=\(autoGupid.isEmpty ? "empty" : "present") ch=\(autoChannels.count)")
        if !autoGupid.isEmpty && autoChannels.count > 1 {
            buildChannelList()
            status = .ready
        }
    }

    // MARK: - Login

    func signIn(username: String, password: String) async -> Bool {
        status = .signingIn
        errorMessage = nil
        debugLog = ""
        dbg("signIn start")

        // Step 1: Login
        let loginReq = LoginX(username: username, pass: password)
        dbg("calling login API...")

        guard let loginResult = await asyncPost(request: loginReq.request, endpoint: loginReq.endpoint) else {
            dbg("login POST failed")
            errorMessage = "Network error during login"
            status = .signedOut
            return false
        }

        dbg("login HTTP \(loginResult.response.statusCode)")

        // Process login using RadioKit's processLogin
        let tuple: PostReturnTuple = (
            message: "login",
            success: true,
            data: loginResult.data,
            response: loginResult.response
        )
        let processed = processLogin(username: username, pass: password, result: tuple)
        dbg("processLogin: \(processed.success) - \(processed.message)")

        if !processed.success {
            errorMessage = processed.message
            status = .signedOut
            return false
        }

        // Step 2: Establish session (required before channels API works)
        dbg("establishing session...")
        let sessionOk = await asyncSession(channelId: "siriushits1")
        dbg("session: \(sessionOk)")

        // Step 3: Load channels
        dbg("loading channels...")
        let channelsReq = Channels()
        dbg("ch endpoint: \(channelsReq.endpoint)")

        // Log cookies being sent
        if let url = URL(string: channelsReq.endpoint),
           let cookies = HTTPCookieStorage.shared.cookies(for: url) {
            dbg("cookies: \(cookies.map { $0.name })")
        } else {
            dbg("NO cookies for channels URL!")
        }

        guard let channelsResult = await asyncPost(request: channelsReq.request, endpoint: channelsReq.endpoint) else {
            dbg("channels POST failed")
            errorMessage = "Network error loading channels"
            status = .signedOut
            return false
        }

        dbg("channels HTTP \(channelsResult.response.statusCode)")

        // Log first few keys of response for debugging
        let topKeys = Array(channelsResult.data.keys.prefix(5))
        dbg("response keys: \(topKeys)")

        // Debug: trace JSON path that processChannels expects
        let chDict = channelsResult.data as NSDictionary
        let mlrObj = chDict.value(forKeyPath: "ModuleListResponse")
        if let mlrDict = mlrObj as? NSDictionary {
            dbg("MLR keys: \(mlrDict.allKeys)")
            let moduleList = mlrDict.value(forKey: "moduleList")
            if let mlDict = moduleList as? NSDictionary {
                dbg("moduleList keys: \(mlDict.allKeys)")
            } else {
                dbg("moduleList: \(String(describing: moduleList).prefix(200))")
            }
            // Check messages for error info
            if let msgs = mlrDict.value(forKey: "messages") as? NSArray {
                dbg("messages: \(msgs)")
            }
        } else {
            dbg("MLR not dict: \(String(describing: mlrObj).prefix(200))")
        }

        let chTuple: PostReturnTuple = (
            message: "channels",
            success: true,
            data: channelsResult.data,
            response: channelsResult.response
        )
        let chProcessed = processChannels(result: chTuple)
        dbg("processChannels: \(chProcessed.success) - \(chProcessed.message)")

        if !chProcessed.success {
            errorMessage = "Channels failed: HTTP \(channelsResult.response.statusCode) - \(chProcessed.message)"
            status = .signedOut
            return false
        }

        // Step 3: Build channel list
        buildChannelList()
        dbg("channels built: \(channels.count)")
        status = .ready
        return true
    }

    // MARK: - Channels

    @discardableResult
    func loadChannels() async -> Bool {
        let channelsReq = Channels()
        guard let result = await asyncPost(request: channelsReq.request, endpoint: channelsReq.endpoint) else {
            return false
        }

        let tuple: PostReturnTuple = (
            message: "channels",
            success: true,
            data: result.data,
            response: result.response
        )
        let processed = processChannels(result: tuple)
        if processed.success {
            buildChannelList()
        }
        return processed.success
    }

    private func buildChannelList() {
        var built: [XMChannel] = []
        var cats: [String] = []

        for (_, value) in userX.channels {
            guard let dict = value as? [String: Any],
                  let channelId = dict["channelId"] as? String,
                  let number = dict["channelNumber"] as? String,
                  let name = dict["name"] as? String else { continue }

            let category = dict["category"] as? String ?? "Other"
            let mediumImage = dict["mediumImage"] as? String ?? ""

            let channel = XMChannel(
                id: channelId,
                number: number,
                name: name,
                category: category,
                mediumImageURL: mediumImage,
                largeImageURL: mediumImage
            )
            built.append(channel)

            if !cats.contains(category) {
                cats.append(category)
            }
        }

        built.sort { (Int($0.number) ?? 0) < (Int($1.number) ?? 0) }
        channels = built
        categories = cats
    }

    // MARK: - Tune

    func tune(channel: XMChannel) async -> URL? {
        currentChannel = channel

        let proxyPort = XMHLSProxyServer.shared.port

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                Session(channelid: channel.id, updateToken: true, updateUser: true)
                cont.resume()
            }
        }

        tokenRefreshTime = currentTimeMs()

        guard proxyPort != 0 else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(proxyPort)
        components.path = "/\(channel.number).m3u8"
        return components.url
    }

    // MARK: - Token Refresh

    func refreshTokenIfNeeded() async {
        guard let channel = currentChannel else { return }
        let elapsed = currentTimeMs() - tokenRefreshTime
        if elapsed >= 480_000 {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    Session(channelid: channel.id, updateToken: true, updateUser: false)
                    cont.resume()
                }
            }
            tokenRefreshTime = currentTimeMs()
        }
    }

    // MARK: - Now Playing

    func updateNowPlaying() async {
        guard let channel = currentChannel else { return }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let endpoint = nowPlayingLive(channelid: channel.id)
                nowPlayingLiveAsync(endpoint: endpoint) { data in
                    guard let data else {
                        cont.resume()
                        return
                    }
                    processNPL(data: data)

                    let markers = data.moduleListResponse.moduleList.modules.first?.moduleResponse.liveChannelData.markerLists
                    if let cutLayer = markers?.first(where: { $0.layer == "cut" }),
                       let marker = cutLayer.markers.first {
                        let artist = marker.cut?.artists.first?.name
                        let song = marker.cut?.title
                        var artURL: String?

                        if let a = artist, let s = song, let key = sha256(a + s), let image = MemBase[key] {
                            artURL = image
                        }

                        Task { @MainActor in
                            self.nowPlayingArtist = artist
                            self.nowPlayingSong = song
                            self.nowPlayingArtURL = artURL

                            if var ch = self.currentChannel {
                                ch.artist = artist
                                ch.song = song
                                ch.albumArtURL = artURL
                                self.currentChannel = ch
                            }
                        }
                    }
                    cont.resume()
                }
            }
        }
    }

    // MARK: - PDT Cache

    func updatePDTCache() async {
        let pdtData: [String: Any] = await withCheckedContinuation { (cont: CheckedContinuation<[String: Any], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let endpoint = PDTendpoint()
                var result: [String: Any] = [:]

                GetPdtSync(endpoint: endpoint, method: "pdt") { data in
                    guard let data else { return }
                    result = processPDT(data: data)
                }

                cont.resume(returning: result)
            }
        }

        pdtCache = pdtData

        for i in channels.indices {
            let number = channels[i].number
            if let info = pdtData[number] as? [String: Any] {
                channels[i].artist = info["artist"] as? String
                channels[i].song = info["song"] as? String
                let image = info["image"] as? String
                channels[i].albumArtURL = (image?.isEmpty == false) ? image : nil
            }
        }
    }

    // MARK: - Playback

    func startPlayback(channel: XMChannel) async {
        currentChannel = channel

        // Start HLS proxy if not running
        if !proxyServer.isRunning {
            do {
                try await proxyServer.start()
            } catch {
                dbg("proxy start failed: \(error)")
                return
            }
        }

        // Get proxy URL
        guard let proxyURL = await tune(channel: channel) else {
            dbg("failed to get proxy URL")
            return
        }

        // Tear down existing player
        playerController?.destruct()
        nowPlayingManager?.invalidate()

        // Create new player
        let controller = WatchAVPlayerController(options: PlayerOptions())
        playerController = controller

        controller.onPropertyChange = { [weak self] property, value in
            Task { @MainActor in
                if case .pause = property, let paused = value as? Bool {
                    self?.isPaused = paused
                    self?.nowPlayingManager?.updatePlaybackState(rate: paused ? 0.0 : 1.0)
                }
            }
        }

        controller.onPlaybackEnded = {
            log.info("playback ended")
        }

        // Now playing manager
        let manager = WatchNowPlayingManager(coordinator: controller)
        nowPlayingManager = manager

        manager.onNextChannel = { [weak self] in
            Task { @MainActor in await self?.nextChannel() }
        }
        manager.onPreviousChannel = { [weak self] in
            Task { @MainActor in await self?.previousChannel() }
        }

        // Play — this activates the audio session
        dbg("playing \(proxyURL.absoluteString)")
        controller.play(proxyURL)
        isPaused = false

        // Set metadata AFTER play so audio session is active and system registers us as Now Playing app
        manager.updateMetadata(
            title: nowPlayingSong ?? channel.name,
            artist: nowPlayingArtist ?? "",
            channel: "\(channel.name) - Ch. \(channel.number)",
            artworkURL: nowPlayingArtURL.flatMap { URL(string: $0) }
        )
        manager.updatePlaybackState(rate: 1.0)

        // Start PDT polling & token refresh
        startPDTPolling()
        startTokenRefresh()
    }

    func togglePlayback() {
        playerController?.togglePlayback()
    }

    func nextChannel() async {
        guard let current = currentChannel else { return }
        guard let idx = channels.firstIndex(where: { $0.id == current.id }) else { return }
        let nextIdx = (idx + 1) % channels.count
        await startPlayback(channel: channels[nextIdx])
    }

    func previousChannel() async {
        guard let current = currentChannel else { return }
        guard let idx = channels.firstIndex(where: { $0.id == current.id }) else { return }
        let prevIdx = idx > 0 ? idx - 1 : channels.count - 1
        await startPlayback(channel: channels[prevIdx])
    }

    private func startPDTPolling() {
        pdtTimer?.cancel()
        pdtTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled else { break }

                await updateNowPlaying()

                // Update lock screen now playing info
                if let channel = currentChannel {
                    nowPlayingManager?.updateMetadata(
                        title: nowPlayingSong ?? channel.name,
                        artist: nowPlayingArtist ?? "",
                        channel: "\(channel.name) - Ch. \(channel.number)",
                        artworkURL: nowPlayingArtURL.flatMap { URL(string: $0) }
                    )
                }
            }
        }
    }

    private func startTokenRefresh() {
        tokenTimer?.cancel()
        tokenTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard !Task.isCancelled else { break }
                await refreshTokenIfNeeded()
            }
        }
    }

    // MARK: - Sign Out

    func signOut() {
        status = .signedOut
        channels = []
        categories = []
        currentChannel = nil
        nowPlayingArtist = nil
        nowPlayingSong = nil
        nowPlayingArtURL = nil
        errorMessage = nil

        UserDefaults.standard.removeObject(forKey: "user")
        UserDefaults.standard.removeObject(forKey: "pass")
        UserDefaults.standard.removeObject(forKey: "gupid")
        UserDefaults.standard.removeObject(forKey: "loggedin")
        UserDefaults.standard.removeObject(forKey: "channels")
        UserDefaults.standard.removeObject(forKey: "ids")
        UserDefaults.standard.removeObject(forKey: "token")
        UserDefaults.standard.removeObject(forKey: "key")
        UserDefaults.standard.removeObject(forKey: "keyurl")
        UserDefaults.standard.removeObject(forKey: "consumer")

        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
    }

    // MARK: - Favorites

    func toggleFavorite(channelNumber: String) {
        if favoriteChannelNumbers.contains(channelNumber) {
            favoriteChannelNumbers.remove(channelNumber)
        } else {
            favoriteChannelNumbers.insert(channelNumber)
        }
    }

    private func saveFavorites() {
        UserDefaults.standard.set(Array(favoriteChannelNumbers), forKey: "xm_favorites")
    }

    // MARK: - Helpers

    private func currentTimeMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}
