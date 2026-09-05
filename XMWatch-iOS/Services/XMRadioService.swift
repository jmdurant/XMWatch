import AVFoundation
import Foundation
import os
import StarPlayrRadioKit

private let log = Logger(subsystem: "com.doctordurant.xmwatch.ios", category: "RadioService")

@MainActor @Observable
final class XMRadioService {
    static let shared = XMRadioService()

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
    private(set) var playerController: AVPlayerController?
    private(set) var nowPlayingManager: NowPlayingManager?
    private(set) var isPaused: Bool = true
    private(set) var isBuffering: Bool = false
    private var proxyServer = XMHLSProxyServer.shared
    private var pdtTimer: Task<Void, Never>?
    private var tokenTimer: Task<Void, Never>?
    private var playbackTask: Task<Bool, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var refreshTask: Task<Bool, Never>?
    private var playbackGeneration = UUID()
    private let httpSession: URLSession
    private let now: () -> Date
    /// True intent to be playing — set when the user starts a channel, cleared
    /// when they pause. Unlike `isPaused`, this is NOT flipped by a stall dropping
    /// the player rate to 0, so recovery uses it to decide whether to keep trying.
    private(set) var userWantsPlayback: Bool = false
    /// True while the recovery loop is actively re-establishing playback.
    private(set) var isReconnecting: Bool = false

    var favoriteChannelNumbers: Set<String> {
        didSet { saveFavorites() }
    }

    private var tokenRefreshTime: Int = 0
    private var pdtCache: [String: Any] = [:]

    init(httpSession: URLSession = .shared, now: @escaping () -> Date = Date.init) {
        self.httpSession = httpSession
        self.now = now
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
        guard UserDefaults.standard.bool(forKey: "xm_debug_mode") else { return }
        debugLog += "\n" + msg
        log.info("\(msg)")
        writeDebug(msg)
    }

    // MARK: - Async Session (replaces Session() to avoid semaphore deadlocks)
    private func asyncSession(channelId: String) async -> Bool {
        let generation = playbackGeneration
        let timeInterval = now().timeIntervalSince1970
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

        guard !Task.isCancelled, generation == playbackGeneration else { return false }

        dbg("session HTTP \(result.response.statusCode)")

        guard result.response.statusCode == 200 else { return false }

        let responseDict = result.data as NSDictionary
        guard let modules = responseDict.value(forKeyPath: "ModuleListResponse.moduleList.modules") as? NSArray,
              let module = modules.firstObject as? NSDictionary,
              let infos = module.value(forKeyPath: "moduleResponse.liveChannelData.customAudioInfos") as? NSArray,
              let info = infos.firstObject as? NSDictionary,
              let chunks = info.value(forKeyPath: "chunks.chunks") as? NSArray,
              let chunk = chunks.firstObject as? NSDictionary,
              let key = chunk["key"] as? String,
              let decodedKey = Data(base64Encoded: key), decodedKey.count == 16,
              chunk["keyUrl"] is String,
              module.value(forKeyPath: "moduleResponse.liveChannelData.hlsConsumptionInfo") is String else {
            dbg("session response missing valid playback keys")
            return false
        }

        // Extract SXMAKTOKEN from cookies
        if let fields = result.response.allHeaderFields as? [String: String],
           let url = result.response.url {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            HTTPCookieStorage.shared.setCookies(cookies, for: url, mainDocumentURL: URL(string: http + root))

            for cookie in cookies where cookie.name == "SXMAKTOKEN" {
                let t = cookie.value
                if t.count > 45 {
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

    /// Full re-login using stored credentials. Recovers a dead session — e.g.
    /// after the app was killed and the auth cookies were lost — without touching
    /// `status` or reloading channels, so playback recovery doesn't bounce the UI
    /// back to the sign-in screen.
    private func reauthenticate() async -> Bool {
        let user = UserDefaults.standard.string(forKey: "user") ?? ""
        let pass = UserDefaults.standard.string(forKey: "pass") ?? ""
        guard !user.isEmpty, !pass.isEmpty else {
            dbg("reauth: no stored credentials")
            return false
        }
        dbg("reauth: logging in again")
        let loginReq = LoginX(username: user, pass: pass)
        guard let loginResult = await asyncPost(request: loginReq.request, endpoint: loginReq.endpoint) else {
            dbg("reauth: login POST failed")
            return false
        }
        guard !Task.isCancelled else { return false }
        let tuple: PostReturnTuple = (
            message: "login",
            success: true,
            data: loginResult.data,
            response: loginResult.response
        )
        let processed = processLogin(username: user, pass: pass, result: tuple)
        dbg("reauth: processLogin \(processed.success)")
        return processed.success
    }

    /// Establish an authenticated session, re-logging-in once if the session
    /// call fails. A failed session is most often a lost/expired auth cookie,
    /// which only a fresh login can restore.
    private func ensureSession(channelId: String) async -> Bool {
        if await asyncSession(channelId: channelId) { return true }
        guard !Task.isCancelled else { return false }
        dbg("session failed — attempting re-login")
        guard await reauthenticate() else { return false }
        return await asyncSession(channelId: channelId)
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
            let (data, response) = try await httpSession.data(for: urlReq)
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

        // Step 2: Establish session
        dbg("establishing session...")
        let sessionOk = await asyncSession(channelId: "siriushits1")
        dbg("session: \(sessionOk)")

        // Step 3: Load channels
        dbg("loading channels...")
        let channelsReq = Channels()
        dbg("ch endpoint: \(channelsReq.endpoint)")

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

        let topKeys = Array(channelsResult.data.keys.prefix(5))
        dbg("response keys: \(topKeys)")

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

        guard await ensureSession(channelId: channel.id) else {
            dbg("tune: could not establish session")
            return nil
        }
        tokenRefreshTime = currentTimeMs()

        let proxyPort = proxyServer.port
        guard proxyPort != 0 else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(proxyPort)
        components.path = "/\(channel.number).m3u8"
        return components.url
    }

    // MARK: - Token Refresh

    @discardableResult
    func refreshTokenIfNeeded() async -> Bool {
        guard let channel = currentChannel, userWantsPlayback else { return false }
        if let refreshTask { return await refreshTask.value }
        guard currentTimeMs() - tokenRefreshTime >= 480_000 else { return true }
        let generation = playbackGeneration
        let task = Task { await self.ensureSession(channelId: channel.id) }
        refreshTask = task
        let success = await task.value
        guard generation == playbackGeneration else { return false }
        refreshTask = nil
        if success { tokenRefreshTime = currentTimeMs() }
        return success
    }

    // MARK: - Now Playing

    func updateNowPlaying() async {
        let generation = playbackGeneration
        guard let channel = currentChannel else { return }

        let endpoint = nowPlayingLive(channelid: channel.id)
        dbg("[NPL] fetching for ch \(channel.number) (\(channel.name)) id=\(channel.id)")
        guard let url = URL(string: endpoint) else { return }

        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "GET"
        urlReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.timeoutInterval = 60

        do {
            let (data, _) = try await httpSession.data(for: urlReq)
            let nplData = try JSONDecoder().decode(NowPlayingLiveStruct.self, from: data)

            guard !Task.isCancelled, generation == playbackGeneration,
                  currentChannel?.id == channel.id,
                  let live = nplData.moduleListResponse.moduleList.modules.first?.moduleResponse.liveChannelData,
                  live.channelID == nil || live.channelID == channel.id else { return }
            processNPL(data: nplData)

            // Use the marker covering the audible wall-clock time, including links/promos.
            let playbackDate = playerController?.player?.currentItem?.currentDate() ?? now()
            let formatter = ISO8601DateFormatter()
            func markerDate(_ value: String) -> Date? {
                if let epoch = Double(value), epoch.isFinite {
                    return Date(timeIntervalSince1970: epoch > 100_000_000_000 ? epoch / 1000 : epoch)
                }
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: value) { return date }
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: value)
            }
            let marker = live.markerLists?.first(where: { $0.layer == "cut" })?.markers
                .compactMap { marker -> (NowPlayingLiveStruct.Marker, Date)? in
                    guard let start = markerDate(marker.timestamp.absolute),
                          start <= playbackDate,
                          marker.duration > 0,
                          playbackDate < start.addingTimeInterval(marker.duration) else { return nil }
                    return (marker, start)
                }
                .max(by: { $0.1 < $1.1 })?.0
            let artist = marker?.cut?.artists.first?.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let song = marker?.cut?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            nowPlayingArtist = artist?.isEmpty == false ? artist : nil
            nowPlayingSong = song?.isEmpty == false ? song : nil
            nowPlayingArtURL = nil
            if let artist = nowPlayingArtist, let song = nowPlayingSong,
               let key = sha256(artist + song) {
                nowPlayingArtURL = MemBase[key] ?? nil
            }
            currentChannel?.artist = nowPlayingArtist
            currentChannel?.song = nowPlayingSong
            currentChannel?.albumArtURL = nowPlayingArtURL
        } catch {
            dbg("[NPL] error: \(error)")
        }
    }

    // MARK: - PDT Cache

    func updatePDTCache() async {
        let endpoint = PDTendpoint()
        guard let url = URL(string: endpoint) else { return }

        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "GET"
        urlReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.timeoutInterval = 60

        var pdtData: [String: Any] = [:]
        do {
            let (data, _) = try await httpSession.data(for: urlReq)
            let decoded = try JSONDecoder().decode(DiscoverChannelList.self, from: data)
            pdtData = processPDT(data: decoded)
        } catch {
            // PDT fetch failed, keep existing cache
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

    @discardableResult
    func startPlayback(channel: XMChannel) async -> Bool {
        cancelPendingPlayback()
        let generation = playbackGeneration
        currentChannel = channel
        userWantsPlayback = true
        isPaused = false
        isBuffering = true
        playerController?.destruct()
        playerController = nil
        nowPlayingManager?.invalidate()
        nowPlayingManager = nil
        let task = Task { await self.performPlayback(channel: channel, generation: generation) }
        playbackTask = task
        let success = await task.value
        guard generation == playbackGeneration else { return false }
        playbackTask = nil
        if !success { startRecoveryIfNeeded() }
        return success
    }

    private func performPlayback(channel: XMChannel, generation: UUID) async -> Bool {
        guard playbackIsCurrent(generation) else { return false }
        isBuffering = true

        UserDefaults.standard.set(channel.number, forKey: "xm_last_channel")

        nowPlayingArtist = nil
        nowPlayingSong = nil
        nowPlayingArtURL = nil

        if !proxyServer.isRunning || proxyServer.port == 0 {
            do {
                try await proxyServer.start()
            } catch {
                guard playbackIsCurrent(generation) else { return false }
                dbg("proxy start failed: \(error)")
                isBuffering = false
                return false
            }
        }

        // Get proxy URL (establishes/refreshes the session, re-logging-in if needed)
        guard playbackIsCurrent(generation) else { return false }
        guard let proxyURL = await tune(channel: channel) else {
            guard playbackIsCurrent(generation) else { return false }
            dbg("failed to get proxy URL")
            isBuffering = false
            return false
        }

        guard playbackIsCurrent(generation), playerController?.isSuspended != true else { return false }
        playerController?.destruct()
        nowPlayingManager?.invalidate()

        let controller = AVPlayerController(options: PlayerOptions())
        playerController = controller

        controller.onPropertyChange = { [weak self, weak controller] property, value in
            Task { @MainActor in
                guard let self, self.playbackIsCurrent(generation), self.playerController === controller else { return }
                switch property {
                case .pause:
                    if let paused = value as? Bool {
                        self.isPaused = paused
                        self.nowPlayingManager?.updatePlaybackState(rate: paused ? 0.0 : 1.0)
                    }
                case .pausedForCache:
                    if let buffering = value as? Bool {
                        self.isBuffering = buffering
                    }
                default:
                    break
                }
            }
        }

        controller.onPlaybackEnded = { [weak self, weak controller] in
            writeDebug("[RadioService] playback ended")
            Task { @MainActor in
                guard let self, self.playbackIsCurrent(generation), self.playerController === controller else { return }
                self.startRecoveryIfNeeded()
            }
        }

        controller.onPlaybackFailed = { [weak self, weak controller] error in
            writeDebug("[RadioService] playback FAILED: \(error?.localizedDescription ?? "unknown")")
            Task { @MainActor in
                guard let self, self.playbackIsCurrent(generation), self.playerController === controller else { return }
                self.isBuffering = false
                self.startRecoveryIfNeeded()
            }
        }

        controller.onPlaybackStalled = { [weak self, weak controller] in
            writeDebug("[RadioService] playback STALLED, reconnecting")
            Task { @MainActor in
                guard let self, self.playbackIsCurrent(generation), self.playerController === controller else { return }
                self.startRecoveryIfNeeded()
            }
        }

        controller.onMediaLoaded = { [weak self, weak controller] in
            Task { @MainActor in
                guard let self, self.playbackIsCurrent(generation), self.playerController === controller else { return }
                self.isBuffering = false
            }
        }

        let manager = NowPlayingManager(coordinator: controller)
        nowPlayingManager = manager

        manager.onTogglePlayback = { [weak self] in
            self?.togglePlayback()
        }
        manager.onNextChannel = { [weak self] in
            Task { @MainActor in await self?.nextChannel() }
        }
        manager.onPreviousChannel = { [weak self] in
            Task { @MainActor in await self?.previousChannel() }
        }

        manager.onPlay = { [weak self] in self?.resumePlayback() }
        manager.onPause = { [weak self] in self?.pausePlayback() }
        controller.onPauseRequested = { [weak self, weak controller] in
            guard let self, self.playerController === controller else { return }
            self.pausePlayback()
        }

        dbg("playing \(proxyURL.absoluteString)")
        controller.play(proxyURL)
        isPaused = false

        let artURL = (nowPlayingArtURL ?? channel.largeImageURL).isEmpty
            ? nil : URL(string: nowPlayingArtURL ?? channel.largeImageURL)
        manager.updateMetadata(
            title: nowPlayingSong ?? channel.name,
            artist: nowPlayingArtist ?? "",
            channel: channel,
            artworkURL: artURL
        )
        manager.updatePlaybackState(rate: 1.0)

        startPDTPolling()
        startTokenRefresh()

        Task { @MainActor in
            for i in 1...5 {
                try? await Task.sleep(nanoseconds: UInt64(i) * 2_000_000_000)
                controller.logPlayerState()
            }
        }
        return true
    }

    private func playbackIsCurrent(_ generation: UUID) -> Bool {
        !Task.isCancelled && generation == playbackGeneration && userWantsPlayback
    }

    private func cancelPendingPlayback() {
        playbackGeneration = UUID()
        playbackTask?.cancel()
        playbackTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        pdtTimer?.cancel()
        pdtTimer = nil
        tokenTimer?.cancel()
        tokenTimer = nil
        isReconnecting = false
    }

    func pausePlayback() {
        userWantsPlayback = false
        cancelPendingPlayback()
        playerController?.pause()
        isPaused = true
        isBuffering = false
        nowPlayingManager?.updatePlaybackState(rate: 0)
    }

    func resumePlayback() {
        guard !userWantsPlayback, let channel = currentChannel else { return }
        // Record intent immediately, so repeated remote play commands are idempotent.
        userWantsPlayback = true
        let generation = playbackGeneration
        Task { [weak self] in
            guard let self, self.playbackIsCurrent(generation) else { return }
            await self.startPlayback(channel: channel)
        }
    }

    func togglePlayback() {
        if userWantsPlayback { pausePlayback() } else { resumePlayback() }
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
                // Fetch immediately on first pass, then every 12s.
                await updateNowPlaying()
                guard !Task.isCancelled else { return }

                if let channel = currentChannel {
                    let artURLString = nowPlayingArtURL ?? channel.largeImageURL
                    let artURL = artURLString.isEmpty ? nil : URL(string: artURLString)
                    dbg("[NP-update] artSource=\(nowPlayingArtURL != nil ? "albumArt" : "channelLogo") url=\(artURLString.prefix(80))")
                    nowPlayingManager?.updateMetadata(
                        title: nowPlayingSong ?? channel.name,
                        artist: nowPlayingArtist ?? "",
                        channel: channel,
                        artworkURL: artURL
                    )
                }

                try? await Task.sleep(nanoseconds: 12_000_000_000)
            }
        }
    }

    private func startTokenRefresh() {
        tokenTimer?.cancel()
        tokenTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { break }
                await refreshTokenIfNeeded()
            }
        }
    }

    // MARK: - Session Recovery

    private func startRecoveryIfNeeded() {
        guard recoveryTask == nil, userWantsPlayback, currentChannel != nil,
              playerController?.isSuspended != true else { return }
        let generation = playbackGeneration
        isReconnecting = true
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.playbackGeneration {
                    self.isReconnecting = false
                    self.recoveryTask = nil
                }
            }
            var attempt = 0
            while self.playbackIsCurrent(generation) {
                attempt += 1
                let delay = min(30, 1 << min(attempt, 5))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard self.playbackIsCurrent(generation), let channel = self.currentChannel else { return }
                if self.playerController?.isSuspended == true { continue }
                if await self.performPlayback(channel: channel, generation: generation) { return }
            }
        }
    }

    func refreshSessionOnForeground() async {
        guard userWantsPlayback, currentChannel != nil,
              playbackTask == nil, recoveryTask == nil else { return }
        let generation = playbackGeneration
        await refreshTokenIfNeeded()
        guard playbackIsCurrent(generation), playbackTask == nil,
              playerController?.isSuspended != true else { return }
        if let player = playerController?.player,
           player.currentItem?.status == .failed || player.currentItem?.isPlaybackBufferEmpty == true {
            startRecoveryIfNeeded()
        } else if playerController == nil {
            startRecoveryIfNeeded()
        }
    }

    // MARK: - Resume Last Channel

    func resumeLastChannelIfEnabled() async {
        guard UserDefaults.standard.bool(forKey: "xm_resume_last_channel"),
              let lastNumber = UserDefaults.standard.string(forKey: "xm_last_channel"),
              let channel = channels.first(where: { $0.number == lastNumber }) else {
            return
        }
        dbg("resuming last channel: \(channel.name) (Ch. \(channel.number))")
        await startPlayback(channel: channel)
    }

    // MARK: - Sign Out

    func signOut() {
        pausePlayback()
        playerController?.destruct()
        playerController = nil
        nowPlayingManager?.invalidate()
        nowPlayingManager = nil
        proxyServer.stop()
        status = .signedOut
        userWantsPlayback = false
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
        Int(now().timeIntervalSince1970 * 1000)
    }
}
