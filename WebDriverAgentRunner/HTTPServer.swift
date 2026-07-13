import Foundation
import Network
import CoreGraphics

final class HTTPServer {
    private let port: UInt16
    private let connectionLimit: Int
    private let handler: (HTTPRequest) -> HTTPResponse
    private let listenerQueue = DispatchQueue(label: "io.github.swiftwda.listener")
    private let connectionQueue = DispatchQueue(label: "io.github.swiftwda.connections", attributes: .concurrent)
    private let stateQueue = DispatchQueue(label: "io.github.swiftwda.server-state")

    private var listener: NWListener?
    private var activeConnections = 0

    init(port: UInt16, connectionLimit: Int = 8, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.port = port
        self.connectionLimit = connectionLimit
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                NSLog("[SwiftWDA] HTTP listener failed: %@", error.localizedDescription)
            }
        }
        listener.start(queue: listenerQueue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: connectionQueue)

        guard reserveConnectionSlot() else {
            send(HTTPResponse.text("Too many open connections", statusCode: 503), on: connection)
            return
        }

        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }

            if let error {
                NSLog("[SwiftWDA] Receive failed: %@", error.localizedDescription)
                self.finish(connection: connection)
                return
            }

            switch Self.parseRequest(from: accumulated) {
            case let .complete(request):
                let response = self.handler(request)
                self.send(response, on: connection)
            case .incomplete:
                if isComplete {
                    self.send(HTTPResponse.text("Incomplete request", statusCode: 400), on: connection)
                } else if accumulated.count > 1_048_576 {
                    self.send(HTTPResponse.text("Payload too large", statusCode: 413), on: connection)
                } else {
                    self.receive(on: connection, buffer: accumulated)
                }
            case let .failure(message):
                self.send(HTTPResponse.text(message, statusCode: 400), on: connection)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { [weak self] _ in
            self?.finish(connection: connection)
        })
    }

    private func finish(connection: NWConnection) {
        connection.cancel()
        releaseConnectionSlot()
    }

    private func reserveConnectionSlot() -> Bool {
        var reserved = false
        stateQueue.sync {
            if activeConnections < connectionLimit {
                activeConnections += 1
                reserved = true
            }
        }
        return reserved
    }

    private func releaseConnectionSlot() {
        stateQueue.sync {
            activeConnections = max(0, activeConnections - 1)
        }
    }

    private enum ParseResult {
        case complete(HTTPRequest)
        case incomplete
        case failure(String)
    }

    private static func parseRequest(from data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else {
            return .incomplete
        }

        let headerData = data[..<range.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .failure("Unable to decode request headers")
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .failure("Missing request line")
        }

        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2,
              let method = HTTPMethod(rawValue: String(requestParts[0]).uppercased()) else {
            return .failure("Unsupported request line")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers.first { $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame }?.value ?? "") ?? 0
        let bodyStart = range.upperBound
        let bodyEnd = bodyStart + contentLength
        guard data.count >= bodyEnd else {
            return .incomplete
        }

        let rawPath = String(requestParts[1])
        let url = URL(string: "http://localhost\(rawPath)")
        let path = url?.path ?? rawPath
        let queryItems = URLComponents(string: "http://localhost\(rawPath)")?.queryItems ?? []

        return .complete(
            HTTPRequest(
                method: method,
                path: path,
                queryItems: Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
                    guard let value = item.value else { return nil }
                    return (item.name, value)
                }),
                headers: headers,
                body: data.subdata(in: bodyStart..<bodyEnd)
            )
        )
    }
}

struct MJPEGStreamSettings {
    let framerate: Int
    let compressionQuality: CGFloat
    let scalingFactor: CGFloat
    let fixOrientation: Bool
}

final class MJPEGServer {
    private let port: UInt16
    private let connectionLimit: Int
    private let settingsProvider: () -> MJPEGStreamSettings
    private let frameProvider: (MJPEGStreamSettings) -> Data?
    private let boundary = "SwiftWDABoundary"
    private let listenerQueue = DispatchQueue(label: "io.github.swiftwda.mjpeg.listener")
    private let connectionQueue = DispatchQueue(label: "io.github.swiftwda.mjpeg.connections", attributes: .concurrent)
    private let streamQueue = DispatchQueue(label: "io.github.swiftwda.mjpeg.stream")
    private let stateQueue = DispatchQueue(label: "io.github.swiftwda.mjpeg.state")

    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var busyClients = Set<UUID>()
    private var publishLoopActive = false
    private var stopped = false

    init(
        port: UInt16,
        connectionLimit: Int = 2,
        settingsProvider: @escaping () -> MJPEGStreamSettings,
        frameProvider: @escaping (MJPEGStreamSettings) -> Data?
    ) {
        self.port = port
        self.connectionLimit = connectionLimit
        self.settingsProvider = settingsProvider
        self.frameProvider = frameProvider
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        self.stopped = false

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                NSLog("[SwiftWDA] MJPEG listener failed: %@", error.localizedDescription)
            }
        }
        listener.start(queue: listenerQueue)
    }

    func stop() {
        stateQueue.sync {
            stopped = true
            let active = Array(clients.values)
            clients.removeAll()
            busyClients.removeAll()
            publishLoopActive = false
            active.forEach { $0.cancel() }
        }
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: connectionQueue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }

            if let error {
                NSLog("[SwiftWDA] MJPEG request receive failed: %@", error.localizedDescription)
                connection.cancel()
                return
            }

            switch Self.parseStreamRequest(from: accumulated) {
            case let .complete(request):
                guard request.method == .get else {
                    self.sendAndClose(HTTPResponse.text("Method not allowed", statusCode: 400), on: connection)
                    return
                }

                guard let clientId = self.register(connection) else {
                    self.sendAndClose(HTTPResponse.text("Too many MJPEG clients", statusCode: 503), on: connection)
                    return
                }

                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .cancelled:
                        self?.unregister(clientId: clientId)
                    case let .failed(error):
                        NSLog("[SwiftWDA] MJPEG client failed: %@", error.localizedDescription)
                        self?.unregister(clientId: clientId)
                    default:
                        break
                    }
                }

                let headers = [
                    "HTTP/1.1 200 OK",
                    "Access-Control-Allow-Origin: *",
                    "Cache-Control: no-cache, no-store, must-revalidate",
                    "Connection: close",
                    "Content-Type: multipart/x-mixed-replace; boundary=\(self.boundary)",
                    "Pragma: no-cache",
                    "",
                    "",
                ].joined(separator: "\r\n")

                connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] error in
                    if let error {
                        NSLog("[SwiftWDA] MJPEG header send failed: %@", error.localizedDescription)
                        self?.unregister(clientId: clientId)
                        return
                    }
                    self?.startPublishLoopIfNeeded()
                })
            case .incomplete:
                if isComplete {
                    self.sendAndClose(HTTPResponse.text("Incomplete request", statusCode: 400), on: connection)
                } else if accumulated.count > 65_536 {
                    self.sendAndClose(HTTPResponse.text("Payload too large", statusCode: 413), on: connection)
                } else {
                    self.receiveRequest(on: connection, buffer: accumulated)
                }
            case let .failure(message):
                self.sendAndClose(HTTPResponse.text(message, statusCode: 400), on: connection)
            }
        }
    }

    private func sendAndClose(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func register(_ connection: NWConnection) -> UUID? {
        stateQueue.sync {
            guard !stopped, clients.count < connectionLimit else { return nil }
            let clientId = UUID()
            clients[clientId] = connection
            return clientId
        }
    }

    private func unregister(clientId: UUID) {
        stateQueue.async {
            self.busyClients.remove(clientId)
            if let connection = self.clients.removeValue(forKey: clientId) {
                connection.cancel()
            }
            if self.clients.isEmpty {
                self.publishLoopActive = false
            }
        }
    }

    private func startPublishLoopIfNeeded() {
        stateQueue.async {
            guard !self.publishLoopActive, !self.clients.isEmpty, !self.stopped else { return }
            self.publishLoopActive = true
            self.scheduleNextPublish(after: 0)
        }
    }

    private func scheduleNextPublish(after delay: TimeInterval) {
        streamQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.publishFrame()
        }
    }

    private func publishFrame() {
        stateQueue.async {
            guard self.publishLoopActive, !self.stopped else {
                self.publishLoopActive = false
                return
            }

            guard !self.clients.isEmpty else {
                self.publishLoopActive = false
                return
            }

            let settings = self.settingsProvider()
            let interval = 1.0 / Double(max(1, settings.framerate))
            let availableClients = self.clients.filter { !self.busyClients.contains($0.key) }

            guard !availableClients.isEmpty else {
                self.scheduleNextPublish(after: interval)
                return
            }

            guard let frame = self.frameProvider(settings) else {
                self.scheduleNextPublish(after: interval)
                return
            }

            let chunk = self.multipartChunk(for: frame)
            for (clientId, connection) in availableClients {
                self.busyClients.insert(clientId)
                connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        NSLog("[SwiftWDA] MJPEG frame send failed: %@", error.localizedDescription)
                        self.unregister(clientId: clientId)
                        return
                    }
                    self.stateQueue.async {
                        self.busyClients.remove(clientId)
                    }
                })
            }

            self.scheduleNextPublish(after: interval)
        }
    }

    private func multipartChunk(for jpegData: Data) -> Data {
        var chunk = Data()
        chunk.append(Data("--\(boundary)\r\n".utf8))
        chunk.append(Data("Content-Type: image/jpeg\r\n".utf8))
        chunk.append(Data("Content-Length: \(jpegData.count)\r\n\r\n".utf8))
        chunk.append(jpegData)
        chunk.append(Data("\r\n".utf8))
        return chunk
    }

    private enum ParseResult {
        case complete(HTTPRequest)
        case incomplete
        case failure(String)
    }

    private static func parseStreamRequest(from data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else {
            return .incomplete
        }

        let headerData = data[..<range.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .failure("Unable to decode request headers")
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .failure("Missing request line")
        }

        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2,
              let method = HTTPMethod(rawValue: String(requestParts[0]).uppercased()) else {
            return .failure("Unsupported request line")
        }

        let rawPath = String(requestParts[1])
        let url = URL(string: "http://localhost\(rawPath)")
        let path = url?.path ?? rawPath
        let queryItems = URLComponents(string: "http://localhost\(rawPath)")?.queryItems ?? []

        return .complete(
            HTTPRequest(
                method: method,
                path: path,
                queryItems: Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
                    guard let value = item.value else { return nil }
                    return (item.name, value)
                }),
                headers: [:],
                body: Data()
            )
        )
    }
}
