import Foundation
import Network

public struct AutomationHTTPResponse: Codable, Equatable, Sendable {
    public let statusCode: Int
    public let body: Data
    public init(statusCode: Int, body: Data) { self.statusCode = statusCode; self.body = body }
}

public actor LocalAutomationRouter {
    private let authorization: AutomationAuthorization
    private let store: AutomationJobStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(authorization: AutomationAuthorization, store: AutomationJobStore? = nil) {
        self.authorization = authorization; self.store = store ?? AutomationJobStore(authorization: authorization)
        self.encoder = JSONEncoder(); self.encoder.dateEncodingStrategy = .iso8601; self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder(); self.decoder.dateDecodingStrategy = .iso8601
    }

    public func handle(method: String, path: String, token: String?, body: Data = Data()) async -> AutomationHTTPResponse {
        guard authorization.isAuthorized(token) else { return response(status: 401, value: ["error": "unauthorized"]) }
        guard body.count <= authorization.maximumRequestBytes else { return response(status: 413, value: ["error": "requestTooLarge"]) }
        do {
            if method == "GET", path == "/health" { return response(status: 200, value: ["status": "ok", "service": "audiolink-local", "apiVersion": "1.0"]) }
            if method == "POST", path == "/v1/jobs/file-analysis" {
                let request = try decoder.decode(AutomationRequest.self, from: body)
                let id = try await store.submit(request: request)
                return response(status: 202, value: ["jobID": id.uuidString, "state": "queued"])
            }
            let components = path.split(separator: "/").map(String.init)
            guard components.count == 4, components[0] == "v1", components[1] == "jobs", let id = UUID(uuidString: components[2]) else {
                return response(status: 404, value: ["error": "notFound"])
            }
            if method == "GET", components[3] == "status" { return response(status: 200, value: try await store.job(id)) }
            if method == "GET", components[3] == "result" { let job = try await store.job(id); return response(status: job.state == .completed ? 200 : 409, value: job) }
            if method == "POST", components[3] == "cancel" { try await store.cancel(id); return response(status: 202, value: ["jobID": id.uuidString, "state": "cancelled"]) }
            return response(status: 404, value: ["error": "notFound"])
        } catch let error as AutomationError { return response(status: 400, value: ["error": error.localizedDescription]) }
        catch { return response(status: 400, value: ["error": error.localizedDescription]) }
    }

    private func response<T: Encodable>(status: Int, value: T) -> AutomationHTTPResponse { AutomationHTTPResponse(statusCode: status, body: (try? encoder.encode(value)) ?? Data("{}".utf8)) }
}

/// Optional localhost-only HTTP server. It is never started implicitly.
public final class LocalAutomationServer: @unchecked Sendable {
    public static let bindAddress = "127.0.0.1"
    public let port: UInt16
    public let authorization: AutomationAuthorization
    private let listener: NWListener
    private let router: LocalAutomationRouter
    private let queue = DispatchQueue(label: "AudioLink.LocalAutomationServer")
    private let connectionLock = NSLock()
    private var activeConnectionCount = 0
    private let maximumConnections = 8
    private let requestTimeout: DispatchTimeInterval = .seconds(15)

    public init(port: UInt16 = 0, authorization: AutomationAuthorization) throws {
        self.port = port; self.authorization = authorization; self.router = LocalAutomationRouter(authorization: authorization)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.acceptLocalOnly = true
        self.listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    public func start() { listener.start(queue: queue) }
    public func stop() { listener.cancel() }
    public var boundPort: UInt16? { listener.port?.rawValue }

    private func accept(_ connection: NWConnection) {
        guard acquireConnection() else {
            connection.cancel()
            return
        }
        let lease = ConnectionLease { [weak self] in self?.releaseConnection() }
        let timeout = AutomationRequestDeadline { [weak connection, weak lease] in
            connection?.cancel()
            lease?.release()
        }
        connection.stateUpdateHandler = { [weak self, weak connection, weak lease] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.receive(connection, lease: lease, timeout: timeout, buffer: Data())
            case .failed, .cancelled:
                timeout.cancel()
                lease?.release()
            default: break
            }
        }
        connection.start(queue: queue)
        timeout.schedule(on: queue, after: requestTimeout)
    }

    private func receive(_ connection: NWConnection, lease: ConnectionLease?, timeout: AutomationRequestDeadline, buffer: Data) {
        let maximumRead = authorization.maximumRequestBytes + 16_384
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(64 * 1024, maximumRead)) { [weak self, weak lease] data, _, isComplete, error in
            guard let self, error == nil, let data else {
                timeout.cancel(); lease?.release(); connection.cancel(); return
            }
            var combined = buffer
            combined.append(data)
            guard combined.count <= maximumRead else {
                timeout.cancel(); lease?.release(); connection.cancel(); return
            }
            guard let headerEnd = combined.range(of: Data([13, 10, 13, 10])) else {
                if isComplete { timeout.cancel(); lease?.release(); connection.cancel(); return }
                self.receive(connection, lease: lease, timeout: timeout, buffer: combined)
                return
            }
            let headerLength = headerEnd.lowerBound + 4
            guard let contentLength = Self.contentLength(in: combined[..<headerEnd.lowerBound]), contentLength >= 0 else {
                timeout.cancel(); lease?.release(); connection.cancel(); return
            }
            let expectedLength = headerLength + contentLength
            guard expectedLength <= maximumRead else {
                timeout.cancel(); lease?.release(); self.sendErrorAndClose(connection, status: 413, lease: lease, timeout: timeout); return
            }
            guard combined.count >= expectedLength else {
                if isComplete { timeout.cancel(); lease?.release(); connection.cancel(); return }
                self.receive(connection, lease: lease, timeout: timeout, buffer: combined)
                return
            }
            guard combined.count == expectedLength, let request = Self.parseRequest(combined) else {
                timeout.cancel(); lease?.release(); connection.cancel(); return
            }
            timeout.cancel()
            Task {
                let response = await self.router.handle(method: request.method, path: request.path, token: request.token, body: request.body)
                let header = "HTTP/1.1 \(response.statusCode) \(Self.reason(response.statusCode))\r\nContent-Type: application/json\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
                let responseLease = lease
                connection.send(content: Data(header.utf8) + response.body, completion: .contentProcessed { _ in
                    responseLease?.release(); connection.cancel()
                })
            }
        }
    }

    private struct ParsedRequest { let method: String; let path: String; let token: String?; let body: Data }
    private static func parseRequest(_ data: Data) -> ParsedRequest? {
        guard let separator = data.range(of: Data([13, 10, 13, 10])),
              let head = String(data: data[..<separator.lowerBound], encoding: .utf8) else { return nil }
        let bodyStart = separator.upperBound
        let body = Data(data[bodyStart...])
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ").map(String.init) ?? []
        guard first.count == 3, ["GET", "POST"].contains(first[0]), first[2].hasPrefix("HTTP/") else { return nil }
        var token: String?
        for line in lines.dropFirst() where line.lowercased().hasPrefix("authorization:") {
            let value = line.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)?.trimmingCharacters(in: .whitespaces)
            guard let value, value.hasPrefix("Bearer ") else { return nil }
            token = String(value.dropFirst("Bearer ".count))
        }
        return ParsedRequest(method: first[0], path: first[1], token: token, body: body)
    }

    private static func contentLength(in header: Data.SubSequence) -> Int? {
        guard let string = String(data: Data(header), encoding: .utf8) else { return nil }
        for line in string.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            let value = line.split(separator: ":", maxSplits: 1).dropFirst().first?.trimmingCharacters(in: .whitespaces)
            return value.flatMap { Int(String($0)) }
        }
        return 0
    }

    private func sendErrorAndClose(_ connection: NWConnection, status: Int, lease: ConnectionLease?, timeout: AutomationRequestDeadline) {
        let body = Data("{\"error\":\"requestTooLarge\"}".utf8)
        let header = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
            timeout.cancel(); lease?.release(); connection.cancel()
        })
    }

    private func acquireConnection() -> Bool {
        connectionLock.lock(); defer { connectionLock.unlock() }
        guard activeConnectionCount < maximumConnections else { return false }
        activeConnectionCount += 1
        return true
    }

    private func releaseConnection() {
        connectionLock.lock(); defer { connectionLock.unlock() }
        activeConnectionCount = max(0, activeConnectionCount - 1)
    }
    private static func reason(_ status: Int) -> String { [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 409: "Conflict", 413: "Payload Too Large"][status] ?? "Error" }
}

private final class ConnectionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private let onRelease: () -> Void

    init(onRelease: @escaping () -> Void) { self.onRelease = onRelease }

    func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        lock.unlock()
        onRelease()
    }
}

/// Dispatch timers are not annotated Sendable in the SDK, but this wrapper
/// exposes only idempotent cancellation and is safe to move between the
/// Network callback queue and the response completion callback.
private final class AutomationRequestDeadline: @unchecked Sendable {
    private let workItem: DispatchWorkItem

    init(_ action: @escaping @Sendable () -> Void) {
        workItem = DispatchWorkItem(block: action)
    }

    func schedule(on queue: DispatchQueue, after interval: DispatchTimeInterval) {
        queue.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    func cancel() { workItem.cancel() }
}
