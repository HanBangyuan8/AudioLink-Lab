import Foundation

public protocol PeerTransport: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data?
    func close() async
}

/// A deterministic actor-isolated transport used by unit tests and simulated peers.
public actor InMemoryPeerTransport: PeerTransport {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Data?, Error>
    }
    private var peer: InMemoryPeerTransport?
    private var queued: [Data] = []
    private var waiters: [Waiter] = []
    private var closed = false

    public init() {}

    public static func pair() async -> (InMemoryPeerTransport, InMemoryPeerTransport) {
        let left = InMemoryPeerTransport()
        let right = InMemoryPeerTransport()
        await left.setPeer(right)
        await right.setPeer(left)
        return (left, right)
    }

    private func setPeer(_ peer: InMemoryPeerTransport) { self.peer = peer }

    public func send(_ data: Data) async throws {
        guard !closed else { throw ProtocolError.transferInterrupted }
        guard let peer else { throw ProtocolError.timeout("peer connection") }
        guard await peer.enqueue(data) else { throw ProtocolError.transferInterrupted }
    }

    private func enqueue(_ data: Data) -> Bool {
        guard !closed else { return false }
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume(returning: data)
        } else {
            queued.append(data)
        }
        return true
    }

    public func receive() async throws -> Data? {
        if let data = queued.first {
            queued.removeFirst()
            return data
        }
        if closed { return nil }
        let waiterID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        })
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume(returning: nil) }
        if let peer { await peer.remoteClosed() }
    }

    private func remoteClosed() {
        closed = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume(returning: nil) }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

public actor PeerConnection {
    public let remoteIdentity: PeerIdentity?
    private let transport: any PeerTransport
    private let limits: ProtocolLimits
    private var isClosed = false

    public init(remoteIdentity: PeerIdentity? = nil, transport: any PeerTransport, limits: ProtocolLimits = .default) {
        self.remoteIdentity = remoteIdentity
        self.transport = transport
        self.limits = limits
    }

    public func send(_ message: ProtocolMessage) async throws {
        guard !isClosed else { throw ProtocolError.transferInterrupted }
        try await transport.send(ProtocolCodec.encode(message, limits: limits))
    }

    public func receive() async throws -> ProtocolMessage? {
        guard !isClosed else { return nil }
        guard let data = try await transport.receive() else { return nil }
        return try ProtocolCodec.decode(data, limits: limits)
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        await transport.close()
    }

    public func reconnect(with transport: any PeerTransport) -> PeerConnection {
        PeerConnection(remoteIdentity: remoteIdentity, transport: transport, limits: limits)
    }
}
