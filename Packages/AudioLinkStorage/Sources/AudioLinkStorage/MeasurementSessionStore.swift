import AudioLinkCore
import Foundation

public protocol MeasurementSessionStore: Sendable {
    func sessions() async throws -> [MeasurementSession]
    func session(id: UUID) async throws -> MeasurementSession?
    func save(_ session: MeasurementSession) async throws
    func deleteSession(id: UUID) async throws
}

public actor InMemoryMeasurementSessionStore: MeasurementSessionStore {
    private var sessionsByID: [UUID: MeasurementSession]

    public init(sessions: [MeasurementSession] = []) {
        sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    }

    public func sessions() -> [MeasurementSession] {
        sessionsByID.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func session(id: UUID) -> MeasurementSession? {
        sessionsByID[id]
    }

    public func save(_ session: MeasurementSession) {
        sessionsByID[session.id] = session
    }

    public func deleteSession(id: UUID) {
        sessionsByID[id] = nil
    }
}

