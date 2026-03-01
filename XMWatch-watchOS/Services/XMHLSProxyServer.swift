import Foundation
import Network
import StarPlayrRadioKit

final class XMHLSProxyServer: @unchecked Sendable {
    static let shared = XMHLSProxyServer()

    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    private let queue = DispatchQueue(label: "com.xmwatch.hlsproxy")
    private(set) var port: UInt16 = 0

    private var tokenRefreshTime: Int = 0

    var isRunning: Bool { listener != nil }

    func start() async throws {
        if isRunning { stop() }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let nwListener = try NWListener(using: parameters, on: .any)

        nwListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let assignedPort = nwListener.port?.rawValue {
                    self?.port = assignedPort
                    writeDebug("[XMHLSProxy] listening on localhost:\(assignedPort)")
                }
            case .failed(let error):
                writeDebug("[XMHLSProxy] listener failed: \(error)")
                self?.stop()
            default:
                break
            }
        }

        nwListener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener = nwListener
        nwListener.start(queue: queue)

        // Wait briefly for the port to be assigned
        for _ in 0..<20 {
            if port != 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        guard port != 0 else {
            stop()
            throw URLError(.cannotConnectToHost)
        }

        tokenRefreshTime = currentTimeMs()
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            for connection in self.activeConnections {
                connection.cancel()
            }
            self.activeConnections.removeAll()
            self.listener?.cancel()
            self.listener = nil
            self.port = 0
            writeDebug("[XMHLSProxy] stopped")
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        activeConnections.append(connection)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed = state, let connection {
                self?.removeConnection(connection)
            }
        }

        connection.start(queue: queue)
        receiveRequest(from: connection)
    }

    private func receiveRequest(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                self?.removeConnection(connection)
                return
            }

            guard let request = self.parseHTTPRequest(data) else {
                self.sendErrorResponse(status: 400, message: "Bad Request", to: connection)
                return
            }

            writeDebug("[XMHLSProxy] \(request.method) \(request.path)")
            self.routeRequest(request, to: connection)
        }
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
    }

    private func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        guard let requestString = String(data: data, encoding: .utf8) else { return nil }
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty { break }
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        return HTTPRequest(method: method, path: path, headers: headers)
    }

    // MARK: - SiriusXM Route Handling

    private func routeRequest(_ request: HTTPRequest, to connection: NWConnection) {
        let path = request.path

        if path.hasSuffix(".m3u8") {
            handlePlaylistRequest(path: path, to: connection)
        } else if path.hasPrefix("/aac/") {
            handleAudioRequest(path: path, to: connection)
        } else if path == "/key" {
            handleKeyRequest(to: connection)
        } else {
            sendErrorResponse(status: 404, message: "Not Found", to: connection)
        }
    }

    // MARK: - Playlist Route (/{channelNumber}.m3u8)

    private func handlePlaylistRequest(path: String, to connection: NWConnection) {
        Task.detached { [weak self] in
            guard let self else { return }

            // Extract channel number from path like "/2.m3u8"
            let filename = (path as NSString).lastPathComponent
            let channelNumber = filename.replacingOccurrences(of: ".m3u8", with: "")

            guard let channelDict = userX.channels[channelNumber] as? NSDictionary,
                  let channelId = channelDict["channelId"] as? String else {
                self.sendErrorResponse(status: 404, message: "Channel not found", to: connection)
                return
            }

            // Ensure current channel is set
            userX.channel = channelId

            // Refresh token if needed (every 480 seconds)
            if (self.currentTimeMs() - self.tokenRefreshTime) >= 480_000 {
                Session(channelid: channelId, updateToken: true, updateUser: false)
                self.tokenRefreshTime = self.currentTimeMs()
            }

            // Get the playlist URL from StarPlayrRadioKit
            let source = Playlist(channelid: channelId)

            // Fetch the m3u8 content
            var playlistText = ""
            TextSync(endpoint: source) { text in
                guard let text else { return }
                playlistText = text
            }

            guard !playlistText.isEmpty else {
                self.sendErrorResponse(status: 502, message: "Failed to fetch playlist", to: connection)
                return
            }

            // Rewrite the m3u8 to route through our proxy
            let rewritten = self.rewriteM3U8(playlistText, channelId: channelId)

            if let body = rewritten.data(using: .utf8) {
                self.sendResponse(status: 200, contentType: "application/vnd.apple.mpegurl", body: body, to: connection)
            } else {
                self.sendErrorResponse(status: 500, message: "Failed to encode playlist", to: connection)
            }
        }
    }

    // MARK: - Audio Route (/aac/{segment})

    private func handleAudioRequest(path: String, to connection: NWConnection) {
        Task.detached { [weak self] in
            guard let self else { return }

            // Extract segment name from /aac/{segment}
            let segment = String(path.dropFirst("/aac/".count))

            let endpoint = AudioX(data: segment, channelId: userX.channel)

            var audioData = Data()
            dataSync(endpoint: endpoint, method: "audio/aac") { data in
                guard let data else { return }
                audioData = data
            }

            guard !audioData.isEmpty else {
                self.sendErrorResponse(status: 502, message: "Failed to fetch audio", to: connection)
                return
            }

            self.sendResponse(status: 200, contentType: "audio/aac", body: audioData, to: connection)
        }
    }

    // MARK: - Key Route (/key)

    private func handleKeyRequest(to connection: NWConnection) {
        guard let data = Data(base64Encoded: userX.key) else {
            sendErrorResponse(status: 404, message: "No key available", to: connection)
            return
        }

        sendResponse(status: 200, contentType: "application/octet-stream", body: data, to: connection)
    }

    // MARK: - M3U8 Rewriting

    private func rewriteM3U8(_ content: String, channelId: String) -> String {
        var playlist = content

        // Rewrite key path to our proxy
        playlist = playlist.replacingOccurrences(of: "key/1", with: "/key")

        // Prefix AAC segment filenames with /aac/
        playlist = playlist.replacingOccurrences(of: channelId, with: "/aac/" + channelId)

        // Fix duration for better PDT sync
        playlist = playlist.replacingOccurrences(of: "#EXT-X-TARGETDURATION:10", with: "#EXT-X-TARGETDURATION:9")
        playlist = playlist.replacingOccurrences(of: "#EXTINF:10,", with: "#EXTINF:1,")

        // Rewrite any remaining absolute URLs to go through localhost
        let lines = playlist.components(separatedBy: "\n")
        var result: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Rewrite absolute HTTPS URLs
            if !trimmed.hasPrefix("#") && !trimmed.isEmpty && trimmed.hasPrefix("http") {
                // This shouldn't happen after the replacements above, but as a safety net
                // extract just the path portion
                if let url = URL(string: trimmed) {
                    let localPath = url.path
                    result.append("http://127.0.0.1:\(port)\(localPath)")
                    continue
                }
            }

            // Rewrite URI= attributes in EXT tags
            if trimmed.hasPrefix("#") && trimmed.contains("URI=\"http") {
                let rewritten = rewriteURIAttributes(in: line)
                result.append(rewritten)
                continue
            }

            result.append(line)
        }

        return result.joined(separator: "\n")
    }

    private func rewriteURIAttributes(in line: String) -> String {
        var result = line
        let pattern = "URI=\"(https?://[^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let nsLine = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))

        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let urlRange = match.range(at: 1)
            let urlString = nsLine.substring(with: urlRange)
            if let url = URL(string: urlString) {
                let localPath = url.path
                let fullRange = match.range(at: 0)
                result = (result as NSString).replacingCharacters(
                    in: fullRange,
                    with: "URI=\"http://127.0.0.1:\(port)\(localPath)\""
                )
            }
        }

        return result
    }

    // MARK: - HTTP Response Helpers

    private func sendResponse(status: Int, contentType: String, body: Data, to connection: NWConnection) {
        let statusText = HTTPURLResponse.localizedString(forStatusCode: status)
        var header = "HTTP/1.1 \(status) \(statusText)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        guard let headerData = header.data(using: .utf8) else {
            connection.cancel()
            removeConnection(connection)
            return
        }

        var fullResponse = headerData
        fullResponse.append(body)

        connection.send(content: fullResponse, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.removeConnection(connection)
        })
    }

    private func sendErrorResponse(status: Int, message: String, to connection: NWConnection) {
        let body = message.data(using: .utf8) ?? Data()
        sendResponse(status: status, contentType: "text/plain", body: body, to: connection)
    }

    private func removeConnection(_ connection: NWConnection) {
        activeConnections.removeAll { $0 === connection }
    }

    private func currentTimeMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}
