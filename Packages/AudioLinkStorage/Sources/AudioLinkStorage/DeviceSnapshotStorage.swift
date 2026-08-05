import Foundation

/// JSON payload is owned by the profiler package; the repository stores it as
/// an opaque versioned blob so storage does not depend on Core Audio.
public struct DeviceSnapshotRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let identity: String
    public let capturedAt: Date
    public let name: String
    public let manufacturer: String?
    public let transport: String
    public let payload: Data
    public let isAnonymized: Bool
    public init(id: UUID = UUID(), identity: String, capturedAt: Date = Date(), name: String, manufacturer: String? = nil, transport: String, payload: Data, isAnonymized: Bool = true) {
        self.id = id; self.identity = identity; self.capturedAt = capturedAt; self.name = name; self.manufacturer = manufacturer; self.transport = transport; self.payload = payload; self.isAnonymized = isAnonymized
    }
}
