import AppIntents
import Foundation
import MediaIntents
import MediaPlayer
import os

// iOS 27 provides an exact assistant-schema match for SiriusXM channels.
// Apple marks the audio assistant schema unavailable on watchOS, so the Watch
// uses the custom entity below with the same tune and playback App Intents.
#if os(iOS)
@AppEntity(schema: .audio.liveRadioStation)
struct XMRadioChannelEntity {
    static let defaultQuery = XMRadioChannelQuery()

    var title: String
    var providerName: String?

    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "Live SiriusXM channel",
            image: .init(systemName: "radio")
        )
    }

    init(_ channel: XMChannel) {
        id = channel.id
        providerName = "SiriusXM"
        title = "\(channel.name), Channel \(channel.number)"
    }
}
#else
struct XMRadioChannelEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Radio Channel"
    )
    static let defaultQuery = XMRadioChannelQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "Live SiriusXM channel",
            image: .init(systemName: "radio")
        )
    }

    init(_ channel: XMChannel) {
        id = channel.id
        title = "\(channel.name), Channel \(channel.number)"
    }
}
#endif

extension XMRadioChannelEntity: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension XMRadioChannelEntity: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct XMRadioChannelQuery: EntityQuery, EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [XMRadioChannelEntity] {
        await XMRadioCatalog.channels()
            .filter { identifiers.contains($0.id) }
            .map(XMRadioChannelEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [XMRadioChannelEntity] {
        let channels = await XMRadioCatalog.channels()
        let favorites = XMRadioService.shared.favoriteChannelNumbers
        return channels
            .sorted {
                let lhsFavorite = favorites.contains($0.number)
                let rhsFavorite = favorites.contains($1.number)
                if lhsFavorite != rhsFavorite { return lhsFavorite }
                return (Int($0.number) ?? 0) < (Int($1.number) ?? 0)
            }
            .prefix(50)
            .map(XMRadioChannelEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [XMRadioChannelEntity] {
        let needle = string.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return await XMRadioCatalog.channels()
            .filter { channel in
                channel.name.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ).contains(needle)
                    || channel.number.contains(needle)
                    || channel.category.folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: .current
                    ).contains(needle)
            }
            .prefix(50)
            .map(XMRadioChannelEntity.init)
    }
}

#if os(iOS)
@UnionValue
enum XMWatchAudioEntity {
    case liveRadioStation(XMRadioChannelEntity)

    var channelID: String {
        switch self {
        case .liveRadioStation(let channel):
            channel.id
        }
    }
}

extension XMWatchAudioEntity {
    struct AudioValueQuery {
        func values(for input: AudioSearch) async throws -> [XMWatchAudioEntity] {
            switch input.criteria {
            case .searchQuery(let query):
                return try await XMRadioChannelQuery()
                    .entities(matching: query)
                    .map(XMWatchAudioEntity.liveRadioStation)
            case .unspecified:
                return try await XMRadioChannelQuery()
                    .suggestedEntities()
                    .map(XMWatchAudioEntity.liveRadioStation)
            case .url(let urls):
                let identifiers = urls.compactMap(XMRadioCatalog.channelID(from:))
                return try await XMRadioChannelQuery()
                    .entities(for: identifiers)
                    .map(XMWatchAudioEntity.liveRadioStation)
            @unknown default:
                return []
            }
        }
    }
}

extension XMWatchAudioEntity.AudioValueQuery: IntentValueQuery {}

@AppEnum(schema: .audio.playbackAttributes)
enum XMWatchPlaybackAttribute: String {
    case shuffle
    case `repeat`

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .shuffle: "Shuffle",
        .repeat: "Repeat",
    ]
}

@AppEnum(schema: .audio.queueInsertionLocation)
enum XMWatchQueueLocation: String {
    case next
    case tail

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .next: "Next",
        .tail: "Last",
    ]
}

@AppEntity(schema: .audio.warmupAudioQueueResult)
struct XMWatchWarmupAudioQueueResult: TransientAppEntity {
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "XMWatch Radio Ready")
    }
}

@AppIntent(schema: .audio.playAudio)
struct XMWatchPlayAudioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play SiriusXM Channel"
    static let description = IntentDescription(
        "Tunes to a live SiriusXM channel in XMWatch."
    )
    static let supportedModes: IntentModes = .foreground(.immediate)

    var audioEntity: XMWatchAudioEntity

    @Parameter(default: [])
    var playbackAttributes: Set<XMWatchPlaybackAttribute>

    var queueLocation: XMWatchQueueLocation?
    var warmupAudioQueueResult: XMWatchWarmupAudioQueueResult?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let tuned = await XMRadioCatalog.play(channelID: audioEntity.channelID)
        return tuned
            ? .result(dialog: "Tuning XMWatch.")
            : .result(dialog: "Open XMWatch and sign in before tuning a channel.")
    }
}
#endif

struct TuneXMChannelIntent: AppIntent {
    static let title: LocalizedStringResource = "Tune SiriusXM Channel"
    static let description = IntentDescription(
        "Tunes XMWatch directly to a SiriusXM channel."
    )
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Channel")
    var channel: XMRadioChannelEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Tune to \(\.$channel)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let tuned = await XMRadioCatalog.play(channelID: channel.id)
        return tuned
            ? .result(dialog: "Tuning \(channel.title).")
            : .result(dialog: "Open XMWatch and sign in before tuning a channel.")
    }
}

struct PauseXMRadioIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause XMWatch"
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult {
        XMRadioCatalog.pause()
        return .result()
    }
}

struct ResumeXMRadioIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume XMWatch"
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let resumed = await XMRadioCatalog.resume()
        return resumed
            ? .result(dialog: "Resuming XMWatch.")
            : .result(dialog: "Choose a channel in XMWatch first.")
    }
}

struct NextXMChannelIntent: AppIntent {
    static let title: LocalizedStringResource = "Next XMWatch Channel"
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult {
        await XMRadioCatalog.next()
        return .result()
    }
}

struct PreviousXMChannelIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous XMWatch Channel"
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult {
        await XMRadioCatalog.previous()
        return .result()
    }
}

struct XMWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TuneXMChannelIntent(),
            phrases: [
                "Tune to \(\.$channel) in \(.applicationName)",
                "Play \(\.$channel) in \(.applicationName)",
            ],
            shortTitle: "Tune Channel",
            systemImageName: "radio"
        )

        AppShortcut(
            intent: PauseXMRadioIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Pause radio in \(.applicationName)",
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )

        AppShortcut(
            intent: ResumeXMRadioIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Continue playing \(.applicationName)",
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )

        AppShortcut(
            intent: NextXMChannelIntent(),
            phrases: [
                "Next channel in \(.applicationName)",
            ],
            shortTitle: "Next Channel",
            systemImageName: "forward.fill"
        )

        AppShortcut(
            intent: PreviousXMChannelIntent(),
            phrases: [
                "Previous channel in \(.applicationName)",
            ],
            shortTitle: "Previous Channel",
            systemImageName: "backward.fill"
        )
    }
}

@MainActor
enum XMRadioCatalog {
    private static var didPrepare = false

    static func channels() async -> [XMChannel] {
        let service = XMRadioService.shared
        if !didPrepare {
            didPrepare = true
            let region = Locale.current.region?.identifier == "CA" ? "CA" : "US"
            await service.configure(region: region)
        }
        if service.channels.isEmpty, service.status == .ready {
            _ = await service.loadChannels()
        }
        return service.channels
    }

    static func play(channelID: String) async -> Bool {
        guard let channel = await channels().first(where: { $0.id == channelID }) else {
            return false
        }
        return await XMRadioService.shared.startPlayback(channel: channel)
    }

    static func pause() {
        let service = XMRadioService.shared
        service.pausePlayback()
    }

    static func resume() async -> Bool {
        let service = XMRadioService.shared
        if service.currentChannel != nil {
            service.resumePlayback()
            return true
        }
        _ = await channels()
        await service.resumeLastChannelIfEnabled()
        return service.currentChannel != nil
    }

    static func next() async {
        guard XMRadioService.shared.currentChannel != nil else { return }
        await XMRadioService.shared.nextChannel()
    }

    static func previous() async {
        guard XMRadioService.shared.currentChannel != nil else { return }
        await XMRadioService.shared.previousChannel()
    }

    nonisolated static func channelID(from url: URL) -> String? {
        guard url.scheme == "xmwatch", url.host == "channel" else { return nil }
        return url.pathComponents.dropFirst().first
    }
}

@MainActor
enum XMRadioEntityDonations {
    private static let logger = Logger(
        subsystem: "com.doctordurant.xmwatch",
        category: "AppIntents"
    )

    static func update(with channel: XMChannel) {
        let entity = XMRadioChannelEntity(channel)
        Task {
            do {
                try await RelevantEntities.shared.updateEntities(
                    [entity],
                    for: .audio(.nowPlaying)
                )
            } catch {
                logger.error(
                    "Radio entity donation failed: \(error.localizedDescription)"
                )
            }
        }
    }

    static func nowPlayingIdentifier(
        for channel: XMChannel
    ) -> MPAppEntityIdentifier? {
        MPAppEntityIdentifier(
            entityIdentifier: EntityIdentifier(for: XMRadioChannelEntity(channel))
        )
    }
}
