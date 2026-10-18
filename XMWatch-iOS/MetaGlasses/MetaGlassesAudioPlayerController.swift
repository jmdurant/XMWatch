import Foundation
@preconcurrency import MWDATCore
@preconcurrency import MWDATDisplay
import Observation
import os

@MainActor
@Observable
final class MetaGlassesAudioPlayerController: @unchecked Sendable {
    static let shared = MetaGlassesAudioPlayerController(wearables: configureWearables(), playback: XMRadioService.shared)

    enum ConnectionState: String {
        case disconnected = "Disconnected"
        case registering = "Registering"
        case registered = "Registered"
        case connecting = "Connecting"
        case connected = "Connected"
        case paused = "Paused"
        case stopping = "Disconnecting"
    }

    struct DetectedDevice: Identifiable {
        let id: DeviceIdentifier
        let name: String
        let supportsDisplay: Bool
        let state: DeviceState

        var summary: String {
            let link = state.linkState == .connected ? "Connected" :
                state.linkState == .connecting ? "Connecting" : "Disconnected"
            let capability = supportsDisplay ? "Display supported" : "No display"
            switch state.compatibility {
            case .deviceUpdateRequired: return "\(link) · Glasses firmware update needed"
            case .sdkUpdateRequired: return "\(link) · XMWatch SDK update needed"
            default: return "\(link) · \(capability)"
            }
        }
    }

    private let wearables: (any WearablesInterface)?
    private let connectionTimeout: Duration
    private let playback: any MetaGlassesRadioPlayback
    private var deviceSession: DeviceSession?
    private var display: Display?
    private var displayStateToken: (any AnyListenerToken)?
    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var sessionStateTask: Task<Void, Never>?
    private var sessionErrorTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var deviceListeners: [DeviceIdentifier: (device: Device, token: any AnyListenerToken)] = [:]
    private var attemptID: UUID?
    private var displayTimer: Timer?
    var isUpdatingPlayback: Bool { displayTimer != nil }
    private var lastSentSnapshot: RadioGlassesSnapshot?
    private var sendTask: Task<Void, Never>?

    var isAvailable: Bool { wearables != nil }
    var canConnect: Bool { isRegistered && !hasConnectionAttempt }
    var hasConnectionAttempt: Bool { attemptID != nil }
    private(set) var isRegistered = false
    private(set) var registrationState = "Unknown"
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var statusMessage = "Register XMWatch with Meta AI to start."
    private(set) var lastError: String?
    private(set) var detectedDevices: [DetectedDevice] = []
    private(set) var isDisplayReady = false

    init(
        wearables: (any WearablesInterface)?,
        playback: any MetaGlassesRadioPlayback,
        connectionTimeout: Duration = .seconds(20)
    ) {
        self.playback = playback
        self.wearables = wearables
        self.connectionTimeout = connectionTimeout
        guard let wearables else {
            registrationState = "Unavailable"
            statusMessage = "Meta glasses are unavailable. You can still play music on this device."
            return
        }
        isRegistered = wearables.registrationState == .registered
        observeRegistration()
        refreshDevices()
        let devicesStream = wearables.devicesStream()
        devicesTask = Task { [weak self] in
            for await _ in devicesStream {
                guard !Task.isCancelled else { return }
                self?.refreshDevices()
            }
        }
    }

    isolated deinit {
        registrationTask?.cancel()
        devicesTask?.cancel()
        sessionStateTask?.cancel()
        sessionErrorTask?.cancel()
        timeoutTask?.cancel()
        displayTimer?.invalidate()
        sendTask?.cancel()
        display?.stop()
        deviceSession?.stop()
        let tokens = deviceListeners.values.map(\.token) + [displayStateToken].compactMap { $0 }
        Task { for token in tokens { await token.cancel() } }
    }

    private static func log(_ message: String) {
        Logger(subsystem: "com.doctordurant.xmwatch", category: "MetaGlasses").info("\(message, privacy: .public)")
    }

    static func configureWearables() -> (any WearablesInterface)? {
        do {
            try Wearables.configure()
        } catch WearablesError.alreadyConfigured {
            return Wearables.shared
        } catch {
            Self.log("mwdat: configure failed: \(error.localizedDescription)")
            return nil
        }
        return Wearables.shared
    }

    func handleOpenURL(_ url: URL) async -> Bool {
        guard let wearables else { return false }
        do {
            return try await wearables.handleUrl(url)
        } catch {
            report(error, action: "Registration callback")
            return false
        }
    }

    func startRegistration() {
        guard let wearables, !isRegistered, connectionState != .registering else { return }
        lastError = nil
        connectionState = .registering
        statusMessage = "Opening Meta AI for registration..."
        Task {
            do {
                try await wearables.startRegistration()
            } catch {
                report(error, action: "Registration")
                connectionState = .disconnected
            }
        }
    }

    func unregister() {
        guard let wearables else { return }
        Task {
            do {
                try await wearables.startUnregistration()
                await disconnect()
            } catch {
                report(error, action: "Remove registration")
            }
        }
    }

    func connect() {
        guard let wearables, !hasConnectionAttempt else { return }
        guard wearables.registrationState == .registered else {
            lastError = "Register XMWatch with Meta AI before connecting."
            return
        }
        lastError = nil
        let attempt = UUID()
        attemptID = attempt
        connectionState = .connecting
        statusMessage = "Looking for display-capable Meta glasses..."
        Self.log("mwdat: connect requested")
        startConnectionTimeout(for: attempt)
        refreshDevices()
    }

    private func startConnectionTimeout(for attempt: UUID) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, connectionTimeout] in
            do { try await Task.sleep(for: connectionTimeout) } catch { return }
            guard let self, self.attemptID == attempt, !self.isDisplayReady else { return }
            self.lastError = self.deviceSession == nil
                ? self.discoveryGuidance
                : "The glasses did not finish connecting. Keep them on and unfolded, check Developer Mode in Meta AI, then retry."
            Self.log("mwdat: connection timed out: \(self.lastError ?? "")")
            self.stopCurrentSession()
        }
    }

    /// Discovery and state callbacks drive readiness; never create a fresh AutoDeviceSelector
    /// and synchronously read its empty initial selection in the same turn.
    func refreshDevices() {
        guard let wearables else { return }
        let devices = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }
        let ids = Set(devices.map(\.identifier))
        for id in Array(deviceListeners.keys) where !ids.contains(id) {
            if let removed = deviceListeners.removeValue(forKey: id) {
                Task { await removed.token.cancel() }
            }
        }
        for device in devices where deviceListeners[device.identifier]?.device !== device {
            if let removed = deviceListeners.removeValue(forKey: device.identifier) {
                Task { await removed.token.cancel() }
            }
            let token = device.addDeviceStateListener { [weak self, weak device] _ in
                Task { @MainActor [weak self, weak device] in
                    guard let self, let device,
                          self.deviceListeners[device.identifier]?.device === device else { return }
                    self.refreshDeviceStatus()
                }
            }
            deviceListeners[device.identifier] = (device, token)
        }
        refreshDeviceStatus()
    }

    private func refreshDeviceStatus() {
        guard let wearables else { return }
        detectedDevices = wearables.devices.compactMap { id in
            guard let device = deviceListeners[id]?.device else { return nil }
            return DetectedDevice(id: id, name: device.nameOrId(), supportsDisplay: device.supportsDisplay(),
                state: DeviceState(linkState: device.linkState, compatibility: device.compatibility(),
                    batteryLevel: device.batteryLevel, chargingState: device.chargingState,
                    donState: device.donState, hingeState: device.hingeState, thermalLevel: device.thermalLevel))
        }
        Self.log("mwdat: discovery \(detectedDevices.map { $0.summary }.joined(separator: "; "))")
        guard connectionState == .connecting, deviceSession == nil, let attempt = attemptID else { return }
        guard let ready = detectedDevices.first(where: {
            $0.supportsDisplay && $0.state.linkState == .connected && $0.state.compatibility == .compatible
        }) else {
            statusMessage = discoveryGuidance
            return
        }
        startSession(device: ready.id, attempt: attempt)
    }

    private var discoveryGuidance: String {
        let displays = detectedDevices.filter(\.supportsDisplay)
        if detectedDevices.isEmpty {
            return "No glasses detected. Keep them on and unfolded, check their Bluetooth connection and Developer Mode in Meta AI, then retry."
        }
        if displays.isEmpty {
            return "The detected glasses do not have a display. Glasses Player requires Meta Ray-Ban Display; ordinary Bluetooth audio uses the iPhone audio output picker."
        }
        if displays.contains(where: { $0.state.compatibility == .deviceUpdateRequired }) {
            return "Update the glasses firmware in Meta AI, then reconnect. The firmware and DAT glasses app have separate updates."
        }
        if displays.contains(where: { $0.state.compatibility == .sdkUpdateRequired }) {
            return "These glasses require a newer Meta SDK in XMWatch. Update XMWatch before reconnecting."
        }
        return "Waiting for the glasses connection and compatibility check. Keep them on and unfolded, and check Bluetooth and Developer Mode in Meta AI."
    }

    private func startSession(device: DeviceIdentifier, attempt: UUID) {
        guard let wearables else { return }
        do {
            let session = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: device))
            deviceSession = session
            let states = session.stateStream()
            let errors = session.errorStream()
            sessionStateTask = Task { [weak self] in
                for await state in states {
                    guard let self, !Task.isCancelled, self.attemptID == attempt else { return }
                    self.handleSessionState(state, session: session)
                }
                // Both streams finish at .stopped. Drain errors before clearing the
                // attempt so a terminal error cannot be hidden by the stopped event.
                await self?.sessionErrorTask?.value
                guard let self, !Task.isCancelled, self.attemptID == attempt else { return }
                self.finishSession()
            }
            sessionErrorTask = Task { [weak self] in
                for await error in errors {
                    guard let self, !Task.isCancelled, self.attemptID == attempt else { return }
                    self.report(error, action: "Glasses session")
                    // Meta documents this as a nonblocking compatibility warning.
                    if error != .dwaOutOfStuRange { self.stopCurrentSession() }
                }
            }
            statusMessage = "Starting XMWatch on glasses..."
            try session.start()
        } catch {
            report(error, action: "Connect")
            stopCurrentSession()
        }
    }

    private func handleSessionState(_ state: DeviceSessionState, session: DeviceSession) {
        guard deviceSession === session else { return }
        Self.log("mwdat: session \(state.description)")
        switch state {
        case .started:
            guard connectionState != .stopping else { return }
            if timeoutTask == nil, let attemptID { startConnectionTimeout(for: attemptID) }
            do {
                if display == nil {
                    let capability = try session.addDisplay()
                    display = capability
                    displayStateToken = capability.statePublisher.listen { [weak self, weak capability] state in
                        Task { @MainActor [weak self, weak capability] in
                            guard let self, let capability, self.display === capability,
                                  self.connectionState != .stopping else { return }
                            self.handleDisplayState(state)
                        }
                    }
                    capability.start()
                } else if display?.state == .started {
                    handleDisplayState(.started)
                }
            } catch {
                report(error, action: "Start glasses display")
                stopCurrentSession()
            }
        case .paused:
            guard connectionState != .stopping else { return }
            timeoutTask?.cancel()
            timeoutTask = nil
            isDisplayReady = false
            stopDisplayUpdates()
            connectionState = .paused
            statusMessage = "Glasses session paused. Waiting for the glasses to resume."
        case .stopping:
            isDisplayReady = false
            stopDisplayUpdates()
            connectionState = .stopping
        case .stopped:
            isDisplayReady = false
            connectionState = .stopping
        case .idle, .starting:
            break
        }
    }

    func disconnect() async {
        let session = deviceSession
        let states = session?.stateStream()
        stopCurrentSession()
        if let states {
            for await state in states {
                if state == .stopped { break }
            }
        }
        if let session, deviceSession === session { await sessionStateTask?.value }
    }

    private func stopCurrentSession() {
        timeoutTask?.cancel()
        timeoutTask = nil
        isDisplayReady = false
        stopDisplayUpdates()
        guard let session = deviceSession else {
            finishSession()
            return
        }
        connectionState = .stopping
        display?.onPlaybackEvent = nil
        display?.stop()
        session.stop()
    }

    /// Keep the SDK session alive until its terminal state, and ignore stale callbacks.
    private func finishSession() {
        attemptID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        sessionStateTask?.cancel()
        sessionStateTask = nil
        sessionErrorTask?.cancel()
        sessionErrorTask = nil
        if let token = displayStateToken { Task { await token.cancel() } }
        displayStateToken = nil
        display = nil
        deviceSession = nil
        isDisplayReady = false
        stopDisplayUpdates()
        connectionState = .disconnected
        statusMessage = "Disconnected. You can connect again when the glasses are ready."
        // Preserve lastError until the user retries; stopped callbacks must not hide it.
    }

    func openDATGlassesAppUpdate() {
        guard let wearables else { return }
        Task {
            do { try await wearables.openDATGlassesAppUpdate() }
            catch { report(error, action: "Open DAT app update") }
        }
    }

    func openFirmwareUpdate() {
        guard let wearables else { return }
        Task {
            do { try await wearables.openFirmwareUpdate() }
            catch { report(error, action: "Open glasses firmware update") }
        }
    }

    private func observeRegistration() {
        guard let wearables else { return }
        registrationState = wearables.registrationState.description
        let states = wearables.registrationStateStream()
        registrationTask = Task { [weak self] in
            for await state in states {
                guard let self, !Task.isCancelled else { return }
                self.registrationState = state.description
                self.isRegistered = state == .registered
                Self.log("mwdat: registration \(state.description)")
                if state == .registered, !self.hasConnectionAttempt {
                    self.connectionState = .registered
                    self.statusMessage = "Registered. Connect to show XMWatch on glasses."
                } else if state == .available || state == .unavailable {
                    self.stopCurrentSession()
                    self.statusMessage = "Register XMWatch with Meta AI to start."
                }
            }
        }
    }

    private func report(_ error: Error, action: String) {
        let message: String
        switch error as? DeviceSessionError {
        case .noEligibleDevice: message = discoveryGuidance
        case .datAppOnTheGlassesUpdateRequired: message = "Update the DAT app on your glasses in Meta AI, return to XMWatch, and reconnect."
        case .insufficientSDKVersion: message = "These glasses require a newer Meta SDK in XMWatch. Update XMWatch before reconnecting."
        case .dwaUnavailable: message = "The DAT app on the glasses is unavailable. Open the DAT app update in Meta AI and check Developer Mode."
        default: message = error.localizedDescription
        }
        lastError = "\(action): \(message)"
        Self.log("mwdat: \(action) failed: \(String(reflecting: error)) — \(message)")
    }

    private func handleDisplayState(_ state: DisplayState) {
        Self.log("mwdat: display \(state)")
        switch state {
        case .started:
            guard deviceSession?.state == .started else { return }
            timeoutTask?.cancel()
            timeoutTask = nil
            isDisplayReady = true
            connectionState = .connected
            statusMessage = "XMWatch is active on your glasses."
            startDisplayUpdates()
            sendCurrent()
        case .starting:
            if connectionState != .paused {
                connectionState = .connecting
                statusMessage = "Starting XMWatch on glasses..."
            }
        case .stopping:
            isDisplayReady = false
            stopDisplayUpdates()
            statusMessage = "Stopping glasses display..."
        case .stopped:
            stopCurrentSession()
        }
    }

    // MARK: - Live radio controls

    private func startDisplayUpdates() {
        displayTimer?.invalidate()
        lastSentSnapshot = nil
        let interval: TimeInterval = ProcessInfo.processInfo.isLowPowerModeEnabled ? 5 : 1
        displayTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sendCurrent() }
        }
    }

    private func stopDisplayUpdates() {
        displayTimer?.invalidate()
        displayTimer = nil
        sendTask?.cancel()
        sendTask = nil
        lastSentSnapshot = nil
    }

    private func sendCurrent() {
        guard let display, isDisplayReady, sendTask == nil else { return }
        let snapshot = playback.glassesSnapshot
        guard snapshot != lastSentSnapshot else { return }
        let attempt = attemptID
        sendTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled, self.attemptID == attempt { self.sendTask = nil }
            }
            guard !Task.isCancelled, self.display === display, isDisplayReady else { return }
            do {
                try await display.send(playerView(for: snapshot))
                guard !Task.isCancelled, self.display === display, isDisplayReady else { return }
                // Failed sends remain eligible for retry on the next tick.
                lastSentSnapshot = snapshot
            } catch {
                guard !Task.isCancelled, self.display === display else { return }
                report(error, action: "Send radio player to glasses")
            }
        }
    }

    private func playerView(for snapshot: RadioGlassesSnapshot) -> FlexBox {
        FlexBox(direction: .column, spacing: 10, crossAlignment: .stretch) {
            FlexBox(direction: .row, spacing: 10, crossAlignment: .center) {
                Icon(name: .musicNote)
                Text(snapshot.title, style: .heading)
            }
            Text(snapshot.subtitle, style: .body, color: .secondary)
            if snapshot.hasChannel && snapshot.subtitle != snapshot.channelLine {
                Text(snapshot.channelLine, style: .meta, color: .secondary)
            }
            Text(snapshot.statusLine, style: .meta, color: .secondary)
            if snapshot.hasChannel { transportButtons(for: snapshot) }
        }
        .padding(24)
        .background(.card)
    }

    /// Shared by the display card and tests, so tests exercise the actual DAT actions.
    func transportButtons(for snapshot: RadioGlassesSnapshot) -> ButtonGroup {
        let attempt = attemptID
        return ButtonGroup {
            Button(label: "Previous", style: .secondary, iconName: .twoTrianglesLeft,
                onClick: { [weak self] in
                    Task { @MainActor [weak self] in await self?.control(.previous, attempt: attempt) }
                })
            Button(label: snapshot.playPauseLabel, style: .primary,
                iconName: snapshot.wantsPlayback ? .twoLinesParallel : .triangleRight,
                onClick: { [weak self] in
                    Task { @MainActor [weak self] in await self?.control(.toggle, attempt: attempt) }
                })
                .actionRole(.primary)
            Button(label: "Next", style: .secondary, iconName: .twoTrianglesRight,
                onClick: { [weak self] in
                    Task { @MainActor [weak self] in await self?.control(.next, attempt: attempt) }
                })
        }
    }

    private enum RadioCommand { case previous, toggle, next }

    private func control(_ command: RadioCommand, attempt: UUID?) async {
        guard let attempt, attemptID == attempt, isDisplayReady,
              playback.glassesSnapshot.hasChannel else { return }
        switch command {
        case .previous: await playback.previousChannel()
        case .toggle: playback.togglePlayback()
        case .next: await playback.nextChannel()
        }
        if attemptID == attempt { sendCurrent() }
    }
}
