import Foundation

/// Makes Network.framework callbacks safe to bridge into async continuations.
/// State handlers can report more than one terminal state (for example
/// failed/cancelled), so resumption must be guarded independently of the
/// connection object.
private final class NetworkContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var finished = false

    @discardableResult
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func finish(returning value: Value) { resolve { $0.resume(returning: value) } }
    func finish(throwing error: Error) { resolve { $0.resume(throwing: error) } }

    private func resolve(_ resume: (CheckedContinuation<Value, Error>) -> Void) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let continuation { resume(continuation) }
    }
}

public struct DiscoveredPeer: Equatable, Sendable, Identifiable {
    public let identity: PeerIdentity
    public let endpointDescription: String
    public let discoveredAt: Date
    public var id: UUID { identity.peerID }
    public init(identity: PeerIdentity, endpointDescription: String, discoveredAt: Date = Date()) {
        self.identity = identity; self.endpointDescription = endpointDescription; self.discoveredAt = discoveredAt
    }
}

public enum DiscoveryEvent: Equatable, Sendable {
    case started
    case peerFound(DiscoveredPeer)
    case peerLost(PeerIdentity)
    case failed(String)
    case stopped
}

public protocol PeerDiscoveryService: Sendable {
    func start() async throws
    func stop() async
    func events() async -> AsyncStream<DiscoveryEvent>
}

public protocol PeerConnectionProviding: PeerDiscoveryService {
    func connect(to peer: DiscoveredPeer, timeoutNanoseconds: UInt64) async throws -> PeerConnection
}

/// A deterministic discovery implementation for app integration tests and simulated peers.
public actor InMemoryPeerDiscoveryService: PeerDiscoveryService {
    private var continuation: AsyncStream<DiscoveryEvent>.Continuation?
    private var peers: [UUID: DiscoveredPeer] = [:]
    private var started = false

    public init() {}

    public func events() async -> AsyncStream<DiscoveryEvent> {
        AsyncStream { continuation in self.continuation = continuation }
    }

    public func start() async throws {
        guard !started else { return }
        started = true
        continuation?.yield(.started)
    }

    public func stop() async {
        guard started else { return }
        started = false
        continuation?.yield(.stopped)
        continuation?.finish()
        continuation = nil
        peers.removeAll()
    }

    public func add(_ peer: DiscoveredPeer) {
        guard started, peers[peer.id] == nil else { return }
        peers[peer.id] = peer
        continuation?.yield(.peerFound(peer))
    }

    public func remove(peerID: UUID) {
        guard let peer = peers.removeValue(forKey: peerID) else { return }
        continuation?.yield(.peerLost(peer.identity))
    }
}

#if canImport(Network)
@preconcurrency import Network

/// Bonjour discovery is kept behind an actor so browser/listener callbacks never mutate UI state directly.
public actor BonjourPeerDiscoveryService: PeerConnectionProviding {
    private let identity: PeerIdentity
    private let serviceType: String
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var continuation: AsyncStream<DiscoveryEvent>.Continuation?
    private var activePeers: [String: DiscoveredPeer] = [:]
#if canImport(Network)
    private var endpointsByPeerID: [UUID: NWEndpoint] = [:]
#endif

    public init(identity: PeerIdentity, serviceType: String = "_audiolink._tcp") {
        self.identity = identity
        self.serviceType = serviceType
    }

    public func events() async -> AsyncStream<DiscoveryEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    public func start() async throws {
        guard browser == nil, listener == nil else { return }
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: identity.displayName, type: serviceType)
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleListenerState(state) }
        }
        listener.newConnectionHandler = { connection in
            // Connection ownership is intentionally handed to PeerConnection by the caller.
            connection.start(queue: .global(qos: .userInitiated))
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener

        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleBrowserState(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { await self?.handleBrowseChanges(results: results, changes: changes) }
        }
        browser.start(queue: .global(qos: .userInitiated))
        self.browser = browser
        continuation?.yield(.started)
    }

    public func stop() async {
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
        continuation?.yield(.stopped)
        continuation?.finish()
        continuation = nil
        activePeers.removeAll()
    }

    private func handleListenerState(_ state: NWListener.State) {
        if case let .failed(error) = state { continuation?.yield(.failed(error.localizedDescription)) }
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        if case let .failed(error) = state { continuation?.yield(.failed(error.localizedDescription)) }
    }

    private func handleBrowseChanges(results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for result in results {
            let key = String(describing: result.endpoint)
            if activePeers[key] == nil {
                let discovered = DiscoveredPeer(
                    identity: PeerIdentity(displayName: key, roles: [.responder]),
                    endpointDescription: key
                )
                activePeers[key] = discovered
#if canImport(Network)
                endpointsByPeerID[discovered.id] = result.endpoint
#endif
                continuation?.yield(.peerFound(discovered))
            }
        }
        for change in changes {
            if case let .removed(result) = change {
                let key = String(describing: result.endpoint)
                if let peer = activePeers.removeValue(forKey: key) {
#if canImport(Network)
                    endpointsByPeerID.removeValue(forKey: peer.id)
#endif
                    continuation?.yield(.peerLost(peer.identity))
                }
            }
        }
    }

    public func connect(to peer: DiscoveredPeer, timeoutNanoseconds: UInt64 = 10_000_000_000) async throws -> PeerConnection {
        guard let endpoint = endpointsByPeerID[peer.id] else {
            throw ProtocolError.invalidState("The discovered peer is no longer available.")
        }
        let transport = NetworkPeerTransport(endpoint: endpoint)
        try await transport.start(timeoutNanoseconds: timeoutNanoseconds)
        return PeerConnection(remoteIdentity: peer.identity, transport: transport)
    }
}

public final class NetworkPeerTransport: PeerTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let maximumFrameBytes: Int
    private let queue = DispatchQueue(label: "AudioLink.NetworkPeerTransport", qos: .userInitiated)

    public init(endpoint: NWEndpoint, parameters: NWParameters = .tcp, maximumFrameBytes: Int = ProtocolLimits.default.maxMessageBytes) {
        self.connection = NWConnection(to: endpoint, using: parameters)
        self.maximumFrameBytes = maximumFrameBytes
    }

    public func start(timeoutNanoseconds: UInt64 = 10_000_000_000) async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.waitUntilReady() }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    throw ProtocolError.timeout("network connection")
                }
                guard let result = try await group.next() else { throw ProtocolError.timeout("network connection") }
                group.cancelAll()
                return result
            }
        } catch {
            // A timeout or failed handshake must not leave a connection that
            // can later become ready and retain its callbacks.
            connection.cancel()
            throw error
        }
    }

    public func send(_ data: Data) async throws {
        guard data.count <= maximumFrameBytes else { throw ProtocolError.messageTooLarge(limit: maximumFrameBytes) }
        var frame = Data()
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(data)
        let gate = NetworkContinuationGate<Void>()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard gate.install(continuation) else { return }
                connection.send(content: frame, completion: .contentProcessed { error in
                    if let error { gate.finish(throwing: ProtocolError.malformedMessage(error.localizedDescription)) }
                    else { gate.finish(returning: ()) }
                })
            }
        }, onCancel: {
            gate.finish(throwing: CancellationError())
            connection.cancel()
        })
    }

    public func receive() async throws -> Data? {
        let prefix = try await receiveChunk(maximumLength: 4)
        guard let prefix, prefix.count == 4 else { return nil }
        let length = (UInt32(prefix[0]) << 24)
            | (UInt32(prefix[1]) << 16)
            | (UInt32(prefix[2]) << 8)
            | UInt32(prefix[3])
        guard length > 0, Int(length) <= maximumFrameBytes else { throw ProtocolError.messageTooLarge(limit: maximumFrameBytes) }
        var data = Data()
        while data.count < Int(length) {
            guard let chunk = try await receiveChunk(maximumLength: Int(length) - data.count) else { throw ProtocolError.transferInterrupted }
            data.append(chunk)
        }
        return data
    }

    public func close() async { connection.cancel() }

    private func waitUntilReady() async throws {
        let gate = NetworkContinuationGate<Void>()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard gate.install(continuation) else { return }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(returning: ())
                case let .failed(error): gate.finish(throwing: ProtocolError.malformedMessage(error.localizedDescription))
                case .cancelled: gate.finish(throwing: ProtocolError.transferInterrupted)
                default: break
                }
            }
            connection.start(queue: queue)
            }
        }, onCancel: {
            gate.finish(throwing: CancellationError())
            self.connection.cancel()
        })
    }

    private func receiveChunk(maximumLength: Int) async throws -> Data? {
        let gate = NetworkContinuationGate<Data?>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                guard gate.install(continuation) else { return }
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { content, _, isComplete, error in
                    if let error { gate.finish(throwing: ProtocolError.malformedMessage(error.localizedDescription)) }
                    else if isComplete && (content == nil || content?.isEmpty == true) { gate.finish(returning: nil) }
                    else { gate.finish(returning: content) }
                }
            }
        }, onCancel: {
            gate.finish(throwing: CancellationError())
            connection.cancel()
        })
    }
}
#endif
