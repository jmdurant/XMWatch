import Foundation
import StarPlayrRadioKit

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

    var favoriteChannelNumbers: Set<String> {
        didSet { saveFavorites() }
    }

    private var tokenRefreshTime: Int = 0
    private var pdtCache: [String: Any] = [:]

    init() {
        // Restore favorites from UserDefaults
        let saved = UserDefaults.standard.stringArray(forKey: "xm_favorites") ?? []
        favoriteChannelNumbers = Set(saved)

        // Check if user was previously logged in
        let autoGupid = UserDefaults.standard.string(forKey: "gupid") ?? ""
        let autoChannels = UserDefaults.standard.dictionary(forKey: "channels") ?? [:]
        if !autoGupid.isEmpty && autoChannels.count > 1 {
            status = .ready
        }
    }

    // MARK: - Configuration

    func configure(region: String) async {
        await Task.detached {
            preflightConfig(location: region)
        }.value

        // Re-check login state after preflight restores cached credentials
        let autoGupid = UserDefaults.standard.string(forKey: "gupid") ?? ""
        let autoChannels = UserDefaults.standard.dictionary(forKey: "channels") ?? [:]
        if !autoGupid.isEmpty && autoChannels.count > 1 {
            status = .ready
            await loadChannels()
        }
    }

    // MARK: - Login

    func signIn(username: String, password: String) async -> Bool {
        status = .signingIn
        errorMessage = nil

        let result: Bool = await Task.detached {
            let loginReq = LoginX(username: username, pass: password)
            var loginSuccess = false

            PostSync(request: loginReq.request, endpoint: loginReq.endpoint, method: loginReq.method) { tuple in
                guard let tuple else { return }
                let processed = processLogin(username: username, pass: password, result: tuple)
                loginSuccess = processed.success
                if !loginSuccess {
                    Task { @MainActor in
                        self.errorMessage = processed.message
                    }
                }
            }

            if loginSuccess {
                // Load channels after login
                let channelsReq = Channels()
                PostSync(request: channelsReq.request, endpoint: channelsReq.endpoint, method: channelsReq.method) { tuple in
                    guard let tuple else { return }
                    let processed = processChannels(result: tuple)
                    if !processed.success {
                        loginSuccess = false
                    }
                }
            }

            return loginSuccess
        }.value

        if result {
            buildChannelList()
            status = .ready
        } else {
            status = .signedOut
        }

        return result
    }

    // MARK: - Channels

    @discardableResult
    func loadChannels() async -> Bool {
        let result: Bool = await Task.detached {
            let channelsReq = Channels()
            var success = false

            PostSync(request: channelsReq.request, endpoint: channelsReq.endpoint, method: channelsReq.method) { tuple in
                guard let tuple else { return }
                let processed = processChannels(result: tuple)
                success = processed.success
            }

            return success
        }.value

        if result {
            buildChannelList()
        }

        return result
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

        // Sort by channel number
        built.sort { (Int($0.number) ?? 0) < (Int($1.number) ?? 0) }
        channels = built
        categories = cats
    }

    // MARK: - Tune

    func tune(channel: XMChannel) async -> URL? {
        currentChannel = channel

        let proxyPort = XMHLSProxyServer.shared.port

        // Start/refresh session for this channel
        await Task.detached {
            Session(channelid: channel.id, updateToken: true, updateUser: true)
        }.value

        tokenRefreshTime = currentTimeMs()

        guard proxyPort != 0 else { return nil }

        // Return proxy URL for this channel's m3u8
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
            await Task.detached {
                Session(channelid: channel.id, updateToken: true, updateUser: false)
            }.value
            tokenRefreshTime = currentTimeMs()
        }
    }

    // MARK: - Now Playing

    func updateNowPlaying() async {
        guard let channel = currentChannel else { return }

        await Task.detached {
            let endpoint = nowPlayingLive(channelid: channel.id)
            nowPlayingLiveAsync(endpoint: endpoint) { data in
                guard let data else { return }
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

                        // Also update the current channel's PDT data
                        if var ch = self.currentChannel {
                            ch.artist = artist
                            ch.song = song
                            ch.albumArtURL = artURL
                            self.currentChannel = ch
                        }
                    }
                }
            }
        }.value
    }

    // MARK: - PDT Cache

    func updatePDTCache() async {
        let pdtData: [String: Any] = await Task.detached {
            let endpoint = PDTendpoint()
            var result: [String: Any] = [:]

            GetPdtSync(endpoint: endpoint, method: "pdt") { data in
                guard let data else { return }
                result = processPDT(data: data)
            }

            return result
        }.value

        pdtCache = pdtData

        // Update channel list with PDT data
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
