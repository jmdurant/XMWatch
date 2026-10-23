import Foundation
import SwiftUI
import XMRadioCore

@MainActor @Observable final class ViewModel {
    static let shared = ViewModel()
    var username = ""
    var password = ""
    var region: RadioRegion = .us
    var query = ""
    var selectedCategory = ""
    var appearance = AppAppearance.system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "xm.android.appearance") }
    }
    var debugMode = false {
        didSet {
            UserDefaults.standard.set(debugMode, forKey: "xm.android.debugMode")
            if !debugMode { diagnosticMessages = [] }
        }
    }
    private(set) var diagnosticMessages: [String] = []
    var selectedTab = "channels"
    var showChannelPicker = false
    private(set) var automationMessage: String?
    private var automationRequestID = UUID()
    private var automationTask: Task<Void, Never>?
    var resumeLastChannel = false {
        didSet { UserDefaults.standard.set(resumeLastChannel, forKey: "xm.android.resumeLastChannel") }
    }
    private(set) var currentChannel: RadioChannel?
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var playbackError: String?
    private(set) var renderedBuffers = 0
    private(set) var userWantsPlayback = false
    private(set) var nowPlayingTitle: String?
    private(set) var nowPlayingArtist: String?
    private(set) var nowPlayingArtwork: URL?
    private var maintenanceTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var recoveryAttempts = 0
    private var nextRetry = Date.distantPast
    private var needsRecovery = false
    private var tuneTask: Task<Void, Never>?
    private var tuneID = UUID()
    private var restored = false
    private var attemptedChannelResume = false
    private var savedSessionAvailable = false
    private var savedSessionRejected = false
    private(set) var restoringSession = false
    private var lastRefresh = Date.distantPast
    private(set) var busy = false
    private(set) var account: String? {
        didSet {
            if account == nil { resetChannelPreviews() }
            updateChannelPreviewMonitoring()
            publishPhoneShortcuts()
        }
    }
    private(set) var channelPreviews: [String: RadioChannelPreview] = [:] {
        didSet { if oldValue != channelPreviews { notifyControllerCatalog() } }
    }
    private var catalogForeground = false
    private var channelPreviewLoop: Task<Void, Never>?
    private var channelPreviewRequest: Task<Void, Never>?
    private var channelPreviewRequestID = UUID()
    private var lastChannelPreviewAttempt = Date.distantPast
    private var lastChannelPreviewSuccess = Date.distantPast
    private(set) var channels: [RadioChannel] = [] {
        didSet { notifyControllerCatalog() }
    }
    private(set) var errorMessage: String?
    private(set) var catalogError: String?
    private(set) var favorites: Set<String> = [] {
        didSet { notifyControllerCatalog() }
    }
    private var client: RadioClient?
    private var pendingAccount: RadioAccount?
    var canRetryChannels: Bool { pendingAccount != nil && client != nil }
    var canRestoreSession: Bool { savedSessionAvailable && !savedSessionRejected && account == nil && !canRetryChannels }
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private let deviceID: String

    init() {
        deviceID = UserDefaults.standard.string(forKey: "xm.android.device") ?? UUID().uuidString
        UserDefaults.standard.set(deviceID, forKey: "xm.android.device")
        appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: "xm.android.appearance") ?? "") ?? .system
        resumeLastChannel = UserDefaults.standard.bool(forKey: "xm.android.resumeLastChannel")
        debugMode = UserDefaults.standard.bool(forKey: "xm.android.debugMode")
        if let savedRegion = UserDefaults.standard.string(forKey: "xm.android.region"),
           let value = RadioRegion(rawValue: savedRegion) { region = value }
        if let json = UserDefaults.standard.string(forKey: "xm.android.favorites"),
           let data = json.data(using: .utf8),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            favorites = Set(saved)
        }
        #if os(Android)
        AndroidRadio.shared.setCommandHandler { [weak self] command in
            Task { @MainActor in self?.handleNativeCommand(command) }
        }
        #endif
        publishPhoneShortcuts()
    }

    /// RadioClient emits fixed field names, counts and numeric codes only.
    /// Keep diagnostics in memory; never append response bodies or request URLs.
    private func recordDiagnostic(_ summary: String) {
        guard debugMode else { return }
        let bounded = String(summary.prefix(512))
        diagnosticMessages.append(bounded)
        if diagnosticMessages.count > 80 { diagnosticMessages.removeFirst(diagnosticMessages.count - 80) }
        logger.info("XMRadio \(bounded)")
    }

    func clearDiagnostics() { diagnosticMessages = [] }

    var filteredChannels: [RadioChannel] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return channels.filter {
            (selectedCategory.isEmpty || $0.category == selectedCategory) &&
            matchesChannel($0, query: text)
        }
    }

    func matchesChannel(_ channel: RadioChannel, query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if text.isEmpty { return true }
        let preview = channelPreviews[channel.id]
        return [channel.name, channel.number, channel.category, preview?.title ?? "", preview?.artist ?? ""].contains {
            $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(text)
        }
    }

    func channelPreviewText(_ id: String) -> String? {
        guard let preview = channelPreviews[id] else { return nil }
        let values = [preview.title, preview.artist].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    func setCatalogForeground(_ active: Bool) {
        guard catalogForeground != active else { return }
        catalogForeground = active
        expireChannelPreviews()
        updateChannelPreviewMonitoring()
    }

    private func updateChannelPreviewMonitoring() {
        channelPreviewLoop?.cancel(); channelPreviewLoop = nil
        guard catalogForeground, account != nil else { return }
        channelPreviewLoop = Task {
            while !Task.isCancelled {
                await refreshChannelPreviewsIfNeeded()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    private func resetChannelPreviews() {
        channelPreviewLoop?.cancel(); channelPreviewLoop = nil
        channelPreviewRequest?.cancel(); channelPreviewRequest = nil
        channelPreviewRequestID = UUID()
        lastChannelPreviewAttempt = .distantPast; lastChannelPreviewSuccess = .distantPast
        if !channelPreviews.isEmpty { channelPreviews = [:] }
    }

    private func expireChannelPreviews() {
        if !channelPreviews.isEmpty, Date().timeIntervalSince(lastChannelPreviewSuccess) >= 90 {
            channelPreviews = [:]
        }
    }

    /// A foreground poll and an external browser share one bulk request. Browsing
    /// refreshes stale metadata on demand without starting a background poll.
    func refreshChannelPreviewsIfNeeded() async {
        expireChannelPreviews()
        guard account != nil, let service = client else { return }
        if let pending = channelPreviewRequest { await pending.value; return }
        guard Date().timeIntervalSince(lastChannelPreviewAttempt) >= 30 else { return }
        let expected = generation, expectedRegion = region, requestID = UUID()
        channelPreviewRequestID = requestID
        lastChannelPreviewAttempt = Date()
        let pending = Task {
            do {
                let values = try await service.channelPreviews()
                guard !Task.isCancelled, generation == expected, client === service,
                      region == expectedRegion, account != nil, channelPreviewRequestID == requestID else { return }
                let catalogIDs = Set(channels.map(\.id))
                channelPreviews = values.filter { catalogIDs.contains($0.key) }
                lastChannelPreviewSuccess = Date()
                await persistSession(service)
            } catch {
                guard !Task.isCancelled, generation == expected, client === service,
                      region == expectedRegion, channelPreviewRequestID == requestID else { return }
                expireChannelPreviews()
            }
        }
        channelPreviewRequest = pending
        await pending.value
        if channelPreviewRequestID == requestID { channelPreviewRequest = nil }
    }

    var categories: [String] {
        Array(Set(channels.map(\.category).filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func refreshCatalog() async {
        guard !busy, account != nil, let service = client else { return }
        let id = generation
        busy = true; catalogError = nil
        defer { if generation == id { busy = false } }
        do {
            let catalog = try await service.channels()
            guard !Task.isCancelled, generation == id, client === service else { return }
            channels = catalog
            if !selectedCategory.isEmpty, !categories.contains(selectedCategory) { selectedCategory = "" }
            await persistSession(service)
        } catch {
            guard !Task.isCancelled, generation == id else { return }
            catalogError = "Couldn't refresh channels. Try again."
        }
    }

    func signIn() {
        guard !busy, !username.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else { return }
        resetChannelPreviews()
        operation?.cancel()
        let id = UUID(); generation = id
        let service = RadioClient(region: region, deviceID: deviceID, diagnostic: { [weak self] summary in
            Task { @MainActor in self?.recordDiagnostic(summary) }
        })
        client = service
        pendingAccount = nil
        let user = username, secret = password
        UserDefaults.standard.set(region.rawValue, forKey: "xm.android.region")
        busy = true; errorMessage = nil
        operation = Task {
            defer { if generation == id { busy = false; password = "" } }
            do {
                let result = try await service.signIn(username: user, password: secret)
                guard !Task.isCancelled, generation == id else { return }
                pendingAccount = result
                await persistSession(service)
                guard !Task.isCancelled, generation == id else { return }
                let catalog = try await service.channels()
                guard !Task.isCancelled, generation == id else { return }
                account = result.username
                channels = catalog
                await persistSession(service)
                resumeSavedChannelIfNeeded()
            } catch {
                guard !Task.isCancelled, generation == id else { return }
                if pendingAccount == nil { client = nil }
                showError(error)
            }
        }
    }

    func retryChannels() {
        guard !busy, let service = client, let signedIn = pendingAccount else { return }
        let id = generation
        busy = true; errorMessage = nil
        operation = Task {
            defer { if generation == id { busy = false } }
            do {
                let catalog = try await service.channels()
                guard !Task.isCancelled, generation == id else { return }
                account = signedIn.username
                channels = catalog
                await persistSession(service)
                resumeSavedChannelIfNeeded()
            } catch {
                guard !Task.isCancelled, generation == id else { return }
                showError(error)
            }
        }
    }

    private func persistSession(_ service: RadioClient) async {
        #if os(Android)
        let expected = generation
        do {
            let json = try await service.savedSession()
            guard generation == expected, client === service else { return }
            if !AndroidRadio.shared.saveSession(json) { logger.info("XMRadio secure session save failed") }
        } catch { logger.info("XMRadio session snapshot unavailable") }
        #endif
    }

    func restoreAndMonitor() async {
        if !restored {
            restored = true
            restoreSavedSession()
        }
        while !Task.isCancelled {
            #if os(Android)
            if let data = AndroidRadio.shared.snapshot().data(using: .utf8),
               let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                isPlaying = snapshot["playing"] as? Bool ?? false
                isBuffering = snapshot["buffering"] as? Bool ?? false
                renderedBuffers = snapshot["renderedBuffers"] as? Int ?? 0
                let failure = snapshot["error"] as? String ?? ""
                if !failure.isEmpty { playbackError = failure }
            }
            #endif
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
    }

    func restoreSavedSession() {
        guard !busy, account == nil else { return }
        resetChannelPreviews()
        #if os(Android)
        let saved = AndroidRadio.shared.loadSession()
        savedSessionAvailable = !saved.isEmpty
        guard savedSessionAvailable else { return }
        operation?.cancel()
        let id = UUID(); generation = id
        let service = RadioClient(region: region, deviceID: deviceID, diagnostic: { [weak self] summary in
            Task { @MainActor in self?.recordDiagnostic(summary) }
        })
        client = service; pendingAccount = nil
        busy = true; restoringSession = true; errorMessage = nil
        // Account restoration belongs to the model. A recreated view must not
        // cancel it or leave the one-time startup attempt permanently busy.
        operation = Task {
            defer { if generation == id { busy = false; restoringSession = false } }
            do {
                let result = try await service.restoreSession(saved)
                guard !Task.isCancelled, generation == id else { return }
                pendingAccount = result
                await persistSession(service)
                guard !Task.isCancelled, generation == id else { return }
                let catalog = try await service.channels()
                guard !Task.isCancelled, generation == id else { return }
                account = result.username; channels = catalog
                await persistSession(service)
                resumeSavedChannelIfNeeded()
            } catch {
                guard !Task.isCancelled, generation == id else { return }
                resetChannelPreviews()
                if authenticationExpired(error) {
                    client = nil; pendingAccount = nil; savedSessionRejected = true
                    errorMessage = "Your saved SiriusXM session has expired. Sign in to renew it."
                } else {
                    if pendingAccount == nil { client = nil }
                    showError(error)
                }
            }
        }
        #endif
    }

    private func resumeSavedChannelIfNeeded() {
        guard !attemptedChannelResume, account != nil else { return }
        attemptedChannelResume = true
        guard resumeLastChannel, currentChannel == nil, !userWantsPlayback,
              let id = UserDefaults.standard.string(forKey: "xm.android.lastChannel"),
              let channel = channels.first(where: { $0.id == id }) else { return }
        play(channel)
    }

    var controllerScope: String { account == nil ? "" : generation.uuidString }
    var controllerResumeChannel: RadioChannel? {
        currentChannel ?? channels.first { $0.id == UserDefaults.standard.string(forKey: "xm.android.lastChannel") }
    }
    func ensureControllerCatalog() async throws -> String {
        // Opening a car's browser must not trigger the phone's optional autoplay.
        if !restored { restored = true; attemptedChannelResume = true }
        if account == nil, !busy, !savedSessionRejected { restoreSavedSession() }
        let expected = generation
        for _ in 0..<300 {
            guard expected == generation, !Task.isCancelled else { throw CancellationError() }
            if !busy { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard account != nil, !busy, client != nil, expected == generation else { throw RadioAPIError.authenticationRejected }
        return generation.uuidString
    }

    func receivePhoneAutomation(_ json: String) {
        struct Request: Decodable {
            let command: String
            let requestID: String
            let channelID: String?
            let number: String?
            let query: String?
            let region: String?
        }
        guard let request = try? JSONDecoder().decode(Request.self, from: Data(json.utf8)) else { return }
        automationTask?.cancel()
        let token = UUID(); automationRequestID = token
        // An explicit launcher command takes precedence over optional launch autoplay.
        attemptedChannelResume = true
        restored = true
        automationMessage = nil
        if account == nil, !busy, !savedSessionRejected { restoreSavedSession() }
        if let requestedRegion = request.region, requestedRegion != region.rawValue {
            automationMessage = "This shortcut belongs to another region. Switch regions in Settings before using it."
            showChannelPicker = true
            return
        }
        if request.command == "pause" {
            cancelPlaybackIntent()
            #if os(Android)
            AndroidRadio.shared.pause()
            #endif
            return
        }
        if request.command == "pick" {
            query = request.query ?? ""; selectedCategory = ""; selectedTab = "channels"
            showChannelPicker = true
        }
        let expectedRegion = region
        automationTask = Task {
            do {
                let scope = try await ensureControllerCatalog()
                guard !Task.isCancelled, token == automationRequestID, expectedRegion == region, scope == controllerScope else { return }
                switch request.command {
                case "pick": break
                case "tune":
                    let matches = channels.filter { channel in
                        if let id = request.channelID { return channel.id == id }
                        if let number = request.number { return channel.number == number }
                        return request.query.map { matchesChannel(channel, query: $0) } ?? false
                    }
                    guard matches.count == 1, let channel = matches.first else {
                        query = request.query ?? request.number ?? ""; selectedCategory = ""; selectedTab = "channels"
                        automationMessage = matches.isEmpty ? "This channel is unavailable in the current region. Choose a channel." : "Several channels match. Choose a channel."
                        showChannelPicker = true
                        return
                    }
                    showChannelPicker = false
                    play(channel)
                case "resume":
                    guard !userWantsPlayback else { return }
                    guard let channel = controllerResumeChannel else {
                        automationMessage = "Choose a channel before resuming."
                        showChannelPicker = true
                        return
                    }
                    play(channel)
                case "next", "previous":
                    guard currentChannel != nil else {
                        automationMessage = "Choose a channel first."
                        showChannelPicker = true
                        return
                    }
                    changeChannel(request.command == "next" ? 1 : -1)
                default: break
                }
            } catch {
                guard !Task.isCancelled, token == automationRequestID, expectedRegion == region else { return }
                automationMessage = errorMessage ?? "No saved session is available. Open Account to connect, then choose a channel."
                showChannelPicker = true
            }
        }
    }

    func pinChannelShortcut(_ channel: RadioChannel) {
        #if os(Android)
        guard account != nil, channels.contains(where: { $0.id == channel.id }) else { return }
        if !PhoneAutomationLink.pin(region.rawValue, channel.id, channel.name, channel.number) {
            catalogError = "This launcher could not add the channel shortcut."
        }
        #endif
    }
    private func publishPhoneShortcuts() {
        #if os(Android)
        let rows: [[String: Any]] = account == nil ? [] : channels.map {
            ["id": $0.id, "name": $0.name, "number": $0.number, "favorite": favorites.contains($0.id)]
        }
        if let data = try? JSONSerialization.data(withJSONObject: ["region": region.rawValue, "channels": rows]) {
            PhoneAutomationLink.synchronize(String(decoding: data, as: UTF8.self))
        }
        #endif
    }

    func play(_ channel: RadioChannel, showPlayer: Bool = true, recovering: Bool = false, controllerToken: String? = nil) {
        if !recovering { automationRequestID = UUID() }
        guard let service = client else { return }
        #if os(Android)
        if let controllerToken {
            guard AndroidRadio.shared.controllerPreparationCurrent(controllerToken) else { return }
        } else { AndroidRadio.shared.cancelControllerPreparation() }
        #endif
        tuneTask?.cancel(); maintenanceTask?.cancel(); metadataTask?.cancel()
        userWantsPlayback = true
        if !recovering { recoveryAttempts = 0; nextRetry = .distantPast; needsRecovery = false }
        let id = UUID(); tuneID = id
        if currentChannel?.id != channel.id {
            nowPlayingTitle = nil; nowPlayingArtist = nil; nowPlayingArtwork = nil
        }
        currentChannel = channel
        if showPlayer { selectedTab = "player" }
        playbackError = nil
        #if os(Android)
        guard AndroidRadio.shared.begin() else {
            cancelPlaybackIntent(); playbackError = "Could not start radio playback."
            if let controllerToken { AndroidRadio.shared.completeControllerPreparation(controllerToken, false) }
            return
        }
        let revision = AndroidRadio.shared.revision
        #endif
        isBuffering = true
        tuneTask = Task {
            do {
                let plan = try await service.playbackPlan(channelID: channel.id)
                guard !Task.isCancelled, tuneID == id else { return }
                #if os(Android)
                guard AndroidRadio.shared.revision == revision else { isBuffering = false; return }
                if let controllerToken, !AndroidRadio.shared.controllerPreparationCurrent(controllerToken) { return }
                let json = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
                guard AndroidRadio.shared.load(json, id: channel.id, title: channel.name,
                    category: channel.category, art: ControllerRadioCatalog.shared.artworkAddress(channel, url: channel.artworkURL), play: controllerToken == nil) else {
                    throw RadioAPIError.malformedResponse
                }
                if let controllerToken { AndroidRadio.shared.completeControllerPreparation(controllerToken, true) }
                #endif
                lastRefresh = Date(); needsRecovery = false; playbackError = nil
                UserDefaults.standard.set(channel.id, forKey: "xm.android.lastChannel")
                await persistSession(service)
                #if os(Android)
                startMaintenance(channel: channel, id: id, revision: revision)
                #endif
            } catch {
                guard !Task.isCancelled, tuneID == id, userWantsPlayback else { return }
                #if os(Android)
                guard AndroidRadio.shared.revision == revision else { return }
                if let controllerToken {
                    AndroidRadio.shared.completeControllerPreparation(controllerToken, false)
                    cancelPlaybackIntent(); AndroidRadio.shared.stop(); return
                }
                #endif
                showError(error); playbackError = errorMessage
                if authenticationExpired(error) {
                    cancelPlaybackIntent()
                    #if os(Android)
                    AndroidRadio.shared.stop()
                    #endif
                } else {
                    needsRecovery = true
                    if nextRetry < Date() { nextRetry = Date().addingTimeInterval(2) }
                    #if os(Android)
                    if AndroidRadio.shared.begin() {
                        startMaintenance(channel: channel, id: id, revision: AndroidRadio.shared.revision)
                    } else { cancelPlaybackIntent() }
                    #endif
                }
            }
        }
    }

    private func authenticationExpired(_ error: Error) -> Bool {
        guard let error = error as? RadioRequestFailure else { return false }
        return error.reason == .authenticationRejected || error.reason == .provider(208) || error.reason == .http(401) || error.reason == .http(403)
    }

    private func cancelPlaybackIntent() {
        automationRequestID = UUID(); automationTask?.cancel(); automationTask = nil
        userWantsPlayback = false; needsRecovery = false
        tuneID = UUID(); tuneTask?.cancel(); tuneTask = nil
        maintenanceTask?.cancel(); maintenanceTask = nil
        metadataTask?.cancel(); metadataTask = nil
        isPlaying = false; isBuffering = false
    }

    private func handleNativeCommand(_ command: String) {
        switch command {
        case "pause", "stop": cancelPlaybackIntent()
        case "next": changeChannel(1, showPlayer: false)
        case "previous": changeChannel(-1, showPlayer: false)
        case "resume":
            guard let channel = currentChannel else { return }
            userWantsPlayback = true
            #if os(Android)
            if nativeSnapshot()?["state"] as? Int == 1 {
                play(channel, showPlayer: false)
                return
            }
            startMaintenance(channel: channel, id: tuneID, revision: AndroidRadio.shared.revision)
            #endif
        default: break
        }
    }

    #if os(Android)
    private func startMaintenance(channel: RadioChannel, id: UUID, revision: Int64) {
        maintenanceTask?.cancel(); metadataTask?.cancel()
        guard let service = client else { return }
        metadataTask = Task {
            while !Task.isCancelled, userWantsPlayback, tuneID == id, AndroidRadio.shared.revision == revision {
                var interval = 12.0
                do {
                    let snapshot = nativeSnapshot()
                    if snapshot?["playing"] as? Bool != true {
                        try await Task.sleep(for: .seconds(1)); continue
                    }
                    let epoch = snapshot?["audibleEpoch"] as? Double ?? 0
                    let audible = epoch > 0 && epoch.isFinite ? Date(timeIntervalSince1970: epoch) : Date()
                    let value = try await service.nowPlaying(channelID: channel.id, audibleDate: audible)
                    guard !Task.isCancelled, userWantsPlayback, tuneID == id, AndroidRadio.shared.revision == revision else { return }
                    if nowPlayingTitle != value.title || nowPlayingArtist != value.artist || nowPlayingArtwork != value.artworkURL {
                        nowPlayingTitle = value.title; nowPlayingArtist = value.artist; nowPlayingArtwork = value.artworkURL
                        AndroidRadio.shared.updateMetadata(id: channel.id, title: value.title ?? channel.name,
                            artist: value.artist ?? channel.category,
                            art: ControllerRadioCatalog.shared.artworkAddress(channel, url: value.artworkURL ?? channel.artworkURL))
                    }
                    interval = value.nextPollSeconds
                } catch { /* Keep playback independent of an unavailable metadata endpoint. */ }
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
        maintenanceTask = Task {
            var lastOutput = -1
            var lastProgress = Date()
            while !Task.isCancelled, userWantsPlayback, tuneID == id, AndroidRadio.shared.revision == revision {
                let snapshot = nativeSnapshot()
                let output = snapshot?["renderedBuffers"] as? Int ?? 0
                let playing = snapshot?["playing"] as? Bool ?? false
                let buffering = snapshot?["buffering"] as? Bool ?? false
                let failure = snapshot?["error"] as? String ?? ""
                isPlaying = playing; isBuffering = buffering
                if output != lastOutput && playing {
                    lastProgress = Date(); recoveryAttempts = 0
                }
                lastOutput = output
                let stalled = buffering && Date().timeIntervalSince(lastProgress) > 30
                if needsRecovery || !failure.isEmpty || stalled {
                    if Date() >= nextRetry {
                        recoveryAttempts += 1
                        nextRetry = Date().addingTimeInterval(min(30, pow(2, Double(min(recoveryAttempts, 5)))))
                        logger.info("XMRadio reconnect attempt=\(recoveryAttempts)")
                        play(channel, showPlayer: false, recovering: true)
                        return
                    }
                } else if Date().timeIntervalSince(lastRefresh) >= 480 && Date() >= nextRetry {
                    do {
                        let plan = try await service.playbackPlan(channelID: channel.id)
                        guard !Task.isCancelled, userWantsPlayback, tuneID == id, AndroidRadio.shared.revision == revision else { return }
                        let json = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
                        if AndroidRadio.shared.renew(json, revision: revision) {
                            lastRefresh = Date(); recoveryAttempts = 0
                            await persistSession(service)
                        } else { needsRecovery = true }
                    } catch {
                        guard !Task.isCancelled, userWantsPlayback, tuneID == id, AndroidRadio.shared.revision == revision else { return }
                        if authenticationExpired(error) {
                            showError(error); playbackError = errorMessage
                            cancelPlaybackIntent(); AndroidRadio.shared.stop(); return
                        }
                        recoveryAttempts += 1
                        nextRetry = Date().addingTimeInterval(min(30, pow(2, Double(min(recoveryAttempts, 5)))))
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func nativeSnapshot() -> [String: Any]? {
        guard let data = AndroidRadio.shared.snapshot().data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    #endif

    func togglePlayback() {
        #if os(Android)
        if userWantsPlayback {
            cancelPlaybackIntent()
            AndroidRadio.shared.pause()        } else if let channel = currentChannel { play(channel) }
        #endif
    }

    func changeChannel(_ offset: Int, showPlayer: Bool = true) {
        guard let current = currentChannel, let index = channels.firstIndex(where: { $0.id == current.id }), !channels.isEmpty else { return }
        play(channels[(index + offset + channels.count) % channels.count], showPlayer: showPlayer)
    }

    private func showError(_ error: Error) {
        if let failure = error as? RadioRequestFailure {
            switch failure.reason {
            case .authenticationRejected: errorMessage = "\(failure.stage.label) was not accepted. Check your SiriusXM credentials."
            case .http(let status): errorMessage = "\(failure.stage.label): SiriusXM returned HTTP \(status). Please try again later."
            case .provider(let code): errorMessage = "\(failure.stage.label): SiriusXM rejected the request (code \(code))."
            case .malformedResponse: errorMessage = "\(failure.stage.label): SiriusXM returned an unexpected response."
            }
        } else { errorMessage = "Could not reach SiriusXM. Check your connection and try again." }
    }

    func switchRegion(_ target: RadioRegion) {
        guard !busy, target != region else { return }
        automationRequestID = UUID(); automationTask?.cancel(); automationTask = nil
        #if os(Android)
        // The current client may hold renewed cookies not yet snapshotted.
        let expected = generation
        let service = client
        busy = true; errorMessage = nil
        operation = Task {
            if let service {
                do {
                    let snapshot = try await service.savedSession()
                    guard generation == expected, client === service else { return }
                    guard AndroidRadio.shared.saveSession(snapshot) else {
                        busy = false; errorMessage = "Couldn't save this region's session. Try again."; return
                    }
                } catch {
                    guard generation == expected else { return }
                    busy = false; errorMessage = "Couldn't save this region's session. Try again."; return
                }
            }
            guard generation == expected else { return }
            guard AndroidRadio.shared.activateRegion(target.rawValue) else {
                busy = false; errorMessage = "Couldn't switch regions. Your current session is unchanged."; return
            }
            let oldRegion = region.rawValue
            let savedFavorites = UserDefaults.standard.string(forKey: "xm.android.favorites") ?? "[]"
            UserDefaults.standard.set(savedFavorites, forKey: "xm.android.region.\(oldRegion).favorites")
            if let last = UserDefaults.standard.string(forKey: "xm.android.lastChannel") {
                UserDefaults.standard.set(last, forKey: "xm.android.region.\(oldRegion).lastChannel")
            } else { UserDefaults.standard.removeObject(forKey: "xm.android.region.\(oldRegion).lastChannel") }
            generation = UUID(); cancelPlaybackIntent(); AndroidRadio.shared.stop()
            client = nil; pendingAccount = nil; account = nil; channels = []; currentChannel = nil
            nowPlayingTitle = nil; nowPlayingArtist = nil; nowPlayingArtwork = nil
            username = ""; password = ""; query = ""; selectedCategory = ""; catalogError = nil
            savedSessionAvailable = false; savedSessionRejected = false; restoringSession = false
            attemptedChannelResume = false; busy = false; region = target; selectedTab = "channels"
            UserDefaults.standard.set(target.rawValue, forKey: "xm.android.region")
            let targetFavorites = UserDefaults.standard.string(forKey: "xm.android.region.\(target.rawValue).favorites") ?? "[]"
            favorites = Set((try? JSONDecoder().decode([String].self, from: Data(targetFavorites.utf8))) ?? [])
            UserDefaults.standard.set(targetFavorites, forKey: "xm.android.favorites")
            if let last = UserDefaults.standard.string(forKey: "xm.android.region.\(target.rawValue).lastChannel") {
                UserDefaults.standard.set(last, forKey: "xm.android.lastChannel")
            } else { UserDefaults.standard.removeObject(forKey: "xm.android.lastChannel") }
            restoreSavedSession()
        }
        #else
        region = target
        #endif
    }

    func signOut() {
        automationRequestID = UUID(); automationTask?.cancel(); automationTask = nil
        resetChannelPreviews()
        clearDiagnostics()
        generation = UUID(); operation?.cancel(); operation = nil
        cancelPlaybackIntent()
        #if os(Android)
        AndroidRadio.shared.stop(); AndroidRadio.shared.clearSession()
        #endif
        currentChannel = nil; isPlaying = false; isBuffering = false; playbackError = nil
        client = nil; pendingAccount = nil; account = nil; channels = []; password = ""; busy = false; errorMessage = nil
        savedSessionAvailable = false; savedSessionRejected = false; restoringSession = false
        attemptedChannelResume = false
        catalogError = nil; query = ""; selectedCategory = ""
        UserDefaults.standard.removeObject(forKey: "xm.android.lastChannel")
    }

    private func notifyControllerCatalog() {
        publishPhoneShortcuts()
        #if os(Android)
        AndroidRadio.shared.catalogChanged()
        #endif
    }

    func toggleFavorite(_ channel: RadioChannel) {
        if favorites.contains(channel.id) { favorites.remove(channel.id) } else { favorites.insert(channel.id) }
        if let data = try? JSONEncoder().encode(Array(favorites).sorted()),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: "xm.android.favorites")
        }
    }
}
