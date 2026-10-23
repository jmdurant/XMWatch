#if SKIP
import Foundation

public final class AndroidRadio {
    public static let shared = AndroidRadio()
    private let context = ProcessInfo.processInfo.androidContext
    private var engine: RadioEngine { RadioEngine.get(context) }
    public var revision: Int64 { engine.revision }
    public func begin() -> Bool { engine.begin() }
    public func load(_ json: String, id: String, title: String, category: String, art: String, play: Bool = true) -> Bool {
        engine.load(json, id, title, category, art, play)
    }
    public func setCommandHandler(_ handler: @escaping (String) -> Void) { engine.commandHandler = handler }
    public func renew(_ json: String, revision: Int64) -> Bool { engine.renew(json, revision) }
    public func updateMetadata(id: String, title: String, artist: String, art: String) { engine.updateMetadata(id, title, artist, art) }
    public func pause() { engine.pause() }
    public func resume() { engine.resume() }
    public func stop() { engine.stop() }
    public func snapshot() -> String { engine.snapshot() }
    public func saveSession(_ json: String) -> Bool { RadioSecureStore.save(context, json) }
    public func loadSession() -> String { RadioSecureStore.load(context) }
    public func activateRegion(_ region: String) -> Bool { RadioSecureStore.activateRegion(context, region) }
    public func clearSession() { RadioSecureStore.clear(context) }
    public var cachePath: String { context.cacheDir.absolutePath }
    public func controllerArtworkAddress(_ id: String) -> String { ControllerArtwork.get(context).address(id) ?? "" }
    public func controllerPreparationCurrent(_ token: String) -> Bool { RadioControllerPreparation.isCurrent(token) }
    public func completeControllerPreparation(_ token: String, _ success: Bool) { RadioControllerPreparation.complete(token, success) }
    public func catalogChanged() { RadioCatalogUpdates.changed() }
    public func cancelControllerPreparation() { RadioControllerPreparation.cancel() }
}
#endif
