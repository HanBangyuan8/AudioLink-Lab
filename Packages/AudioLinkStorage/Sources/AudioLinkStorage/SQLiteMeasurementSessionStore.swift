import AudioLinkCore
import Foundation

/// Persistence adapter for the original session-store API.
///
/// The current history UI uses `MeasurementRepository` directly. Older
/// dashboard code still speaks `MeasurementSessionStore`; keeping this adapter
/// backed by the same SQLite repository prevents that compatibility path from
/// silently losing sessions on restart. The payload is opaque to SQLite and is
/// versioned independently from the relational history schema.
public actor SQLiteMeasurementSessionStore: MeasurementSessionStore {
    public static let artifactKind = "legacy.measurement-session.v1"

    private struct PersistedSession: Codable, Sendable {
        let schemaVersion: Int
        let session: MeasurementSession

        init(session: MeasurementSession) {
            schemaVersion = 1
            self.session = session
        }
    }

    private let repository: any MeasurementRepository
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(repository: any MeasurementRepository) {
        self.repository = repository
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func sessions() async throws -> [MeasurementSession] {
        try await loadAll().sorted { $0.createdAt > $1.createdAt }
    }

    public func session(id: UUID) async throws -> MeasurementSession? {
        try await loadAll().first { $0.id == id }
    }

    public func save(_ session: MeasurementSession) async throws {
        do {
            let payload = try encoder.encode(PersistedSession(session: session))
            try await repository.saveLabArtifact(
                LabArtifactRecord(
                    id: session.id,
                    kind: Self.artifactKind,
                    createdAt: session.createdAt,
                    updatedAt: Date(),
                    payload: payload,
                    isAnonymized: true
                )
            )
        } catch let error as MeasurementStorageError {
            throw error
        } catch {
            throw MeasurementStorageError.encodingFailed(
                type: "MeasurementSession",
                message: error.localizedDescription
            )
        }
    }

    public func deleteSession(id: UUID) async throws {
        try await repository.deleteLabArtifact(id: id)
    }

    private func loadAll() async throws -> [MeasurementSession] {
        let records = try await repository.labArtifacts(kind: Self.artifactKind)
        return try records.map { record in
            do {
                let persisted = try decoder.decode(PersistedSession.self, from: record.payload)
                guard persisted.schemaVersion == 1 else {
                    throw MeasurementStorageError.decodingFailed(
                        type: "MeasurementSession",
                        message: "Unsupported compatibility payload version \(persisted.schemaVersion)."
                    )
                }
                return persisted.session
            } catch let error as MeasurementStorageError {
                throw error
            } catch {
                throw MeasurementStorageError.decodingFailed(
                    type: "MeasurementSession",
                    message: error.localizedDescription
                )
            }
        }
    }
}
