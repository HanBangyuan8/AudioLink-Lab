import Foundation

/// Opaque, versioned JSON blobs for v1.1 labs. The owning package controls the
/// payload schema; storage only guarantees atomic persistence and privacy flags.
public struct LabArtifactRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: String
    public let createdAt: Date
    public let updatedAt: Date
    public let payload: Data
    public let isAnonymized: Bool
    public init(id: UUID = UUID(), kind: String, createdAt: Date = Date(), updatedAt: Date = Date(), payload: Data, isAnonymized: Bool = true) {
        self.id = id; self.kind = kind; self.createdAt = createdAt; self.updatedAt = updatedAt; self.payload = payload; self.isAnonymized = isAnonymized
    }
}
