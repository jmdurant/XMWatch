import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XMRadioCore

/// Controller IDs identify catalog records, never stream URLs or credentials.
@MainActor final class ControllerRadioCatalog {
    static let shared = ControllerRadioCatalog()
    private struct Node {
        var kind: String
        var title: String
        var channel: RadioChannel?
        var imageURL: URL?
        var query = ""
        var start = 0
    }
    private var scope = ""
    private var nodes: [String: Node] = [:]
    private var ids: [String: String] = [:]
    private var images: [String: URL] = [:]
    private let root = "media:v1:W10"
    private let resume = "media:v1:WyJyZXN1bWUiXQ"
    private func store(_ node: Node) throws -> String {
        let key = [node.kind, node.channel?.id ?? "", node.imageURL?.absoluteString ?? "", node.query, String(node.start)]
            .map { "\($0.utf8.count):\($0)" }.joined()
        if let id = ids[key] { nodes[id] = node; return id }
        guard nodes.count < 10000 else { throw RadioAPIError.malformedResponse }
        let id = "media:v1:" + UUID().uuidString
        nodes[id] = node; ids[key] = id; return id
    }
    private func row(_ id: String) throws -> [String: Any] {
        guard let node = nodes[id], node.kind != "artwork" else { throw RadioAPIError.malformedResponse }
        var result: [String: Any] = ["id": id, "title": String(node.title.prefix(512)),
            "subtitle": node.channel.map { "Channel \($0.number) · \($0.category)" } ?? "",
            "playable": node.channel != nil, "browsable": node.channel == nil]
        if let channel = node.channel, let preview = ViewModel.shared.channelPreviewText(channel.id) {
            result["subtitle"] = String("Channel \(channel.number) · \(preview)".prefix(512))
        }
        if node.channel?.artworkURL != nil { result["artworkID"] = id }
        return result
    }
    private func tracks(_ channels: [RadioChannel]) throws -> [String] {
        try channels.map { try store(Node(kind: "channel", title: $0.name, channel: $0)) }
    }
    private func matches(_ query: String, channels: [RadioChannel]) -> [RadioChannel] {
        channels.filter { ViewModel.shared.matchesChannel($0, query: query) }
    }
    func browse(_ request: String) async -> String {
        do {
            guard let arguments = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any],
                let op = arguments["op"] as? String else { throw RadioAPIError.malformedResponse }
            let model = ViewModel.shared
            let current = try await model.ensureControllerCatalog()
            await model.refreshChannelPreviewsIfNeeded()
            guard !Task.isCancelled, model.controllerScope == current else { throw CancellationError() }
            if scope != current { nodes.removeAll(); ids.removeAll(); images.removeAll(); scope = current }
            let id = arguments["id"] as? String ?? ""
            var result: [String] = []
            if op == "resumption" || (op == "item" && id == resume) {
                guard let channel = model.controllerResumeChannel else { throw RadioAPIError.malformedResponse }
                var metadata = try row(try tracks([channel])[0])
                metadata["id"] = resume; metadata["positionMs"] = 0
                return try encode([metadata])
            }
            switch op {
            case "item":
                if id == root { return #"[{"id":"media:v1:W10","title":"XMWatch","playable":false,"browsable":true}]"# }
                result = [id]
            case "children":
                if id == root {
                    result = try [Node(kind: "all", title: "All Channels"), Node(kind: "favorites", title: "Favorites"),
                        Node(kind: "categories", title: "Categories")].map { try store($0) }
                } else {
                    guard let node = nodes[id], node.channel == nil else { throw RadioAPIError.malformedResponse }
                    if node.kind == "categories" {
                        let values = model.categories
                        let begin = min(node.start, values.count); let end = min(begin + 60, values.count)
                        result = try values[begin..<end].map { try store(Node(kind: "category", title: $0, query: $0)) }
                        if end < values.count { var more = node; more.title = "More…"; more.start = end; result.append(try store(more)) }
                    } else {
                        let channels: [RadioChannel]
                        switch node.kind {
                        case "all": channels = model.channels
                        case "favorites": channels = model.channels.filter { model.favorites.contains($0.id) }
                        case "category": channels = model.channels.filter { $0.category == node.query }
                        case "search": channels = matches(node.query, channels: model.channels)
                        default: throw RadioAPIError.malformedResponse
                        }
                        let begin = min(node.start, channels.count); let end = min(begin + 60, channels.count)
                        result = try tracks(Array(channels[begin..<end]))
                        if end < channels.count { var more = node; more.title = "More…"; more.start = end; result.append(try store(more)) }
                    }
                }
            case "search", "searchCount":
                let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty, query.count <= 256 else { throw RadioAPIError.malformedResponse }
                let channels = matches(query, channels: model.channels)
                if op == "searchCount" { return "[{\"count\":\(channels.count)}]" }
                if arguments["grouped"] as? Bool == true, channels.count > 60 {
                    result = try stride(from: 0, to: channels.count, by: 60).map { start in
                        try store(Node(kind: "search", title: "Results \(start + 1)–\(min(start + 60, channels.count))", query: query, start: start))
                    }
                } else { result = try tracks(channels) }
            default: throw RadioAPIError.malformedResponse
            }
            if op != "item" {
                let page = arguments["page"] as? Int ?? 0, size = arguments["pageSize"] as? Int ?? 100
                guard page >= 0, page <= 100000, size > 0, size <= 100 else { throw RadioAPIError.malformedResponse }
                let begin = min(result.count, page * size); let end = min(begin + size, result.count)
                result = Array(result[begin..<end])
            }
            guard model.controllerScope == current else { throw CancellationError() }
            return try encode(result.map { try row($0) })
        } catch { return "null" }
    }
    private func encode(_ rows: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
    }
    func prepare(_ id: String, query: String, token: String) async {
        #if os(Android)
        do {
            let model = ViewModel.shared
            let current = try await model.ensureControllerCatalog()
            if !query.isEmpty { await model.refreshChannelPreviewsIfNeeded() }
            guard model.controllerScope == current else { throw CancellationError() }
            guard AndroidRadio.shared.controllerPreparationCurrent(token) else { return }
            let channel: RadioChannel?
            if id.isEmpty, !query.isEmpty, query.count <= 256 { channel = matches(query, channels: model.channels).first }
            else if id == resume { channel = model.controllerResumeChannel }
            else { channel = current == scope && nodes[id]?.kind == "channel" ? nodes[id]?.channel : nil }
            guard let channel, model.channels.contains(where: { $0.id == channel.id }) else { throw RadioAPIError.malformedResponse }
            model.play(channel, showPlayer: false, controllerToken: token)
        } catch { AndroidRadio.shared.completeControllerPreparation(token, false) }
        #endif
    }
    func artworkAddress(_ channel: RadioChannel, url: URL?) -> String {
        #if os(Android)
        let current = ViewModel.shared.controllerScope
        guard !current.isEmpty, let url else { return "" }
        if scope != current { nodes.removeAll(); ids.removeAll(); images.removeAll(); scope = current }
        guard let id = try? store(Node(kind: "artwork", title: channel.name, channel: channel, imageURL: url)) else { return "" }
        return AndroidRadio.shared.controllerArtworkAddress(id)
        #else
        return ""
        #endif
    }
    func artwork(_ id: String) async -> String {
        #if os(Android)
        let model = ViewModel.shared, current = scope
        guard model.controllerScope == current, let node = nodes[id], let url = node.imageURL ?? node.channel?.artworkURL else { return "" }
        if let file = images[url.absoluteString], FileManager.default.fileExists(atPath: file.path) { return file.path }
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 8
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                response.url?.scheme == "https", data.count <= 8 * 1024 * 1024,
                model.controllerScope == current, scope == current else { return "" }
            let root = URL(fileURLWithPath: AndroidRadio.shared.cachePath).appendingPathComponent("posters", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
            try data.write(to: file, options: .atomic); images[url.absoluteString] = file
            // Original images are bounded too, independently of the provider's
            // bounded JPEG cache. Deleted cache entries are fetched again on demand.
            let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            let sorted = files.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            var count = sorted.count
            var bytes = sorted.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            for old in sorted where old != file {
                if count <= 64, bytes <= 16 * 1024 * 1024 { break }
                let size = (try? old.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if (try? FileManager.default.removeItem(at: old)) != nil { count -= 1; bytes -= size }
            }
            return file.path
        } catch { return "" }
        #else
        return ""
        #endif
    }
}
