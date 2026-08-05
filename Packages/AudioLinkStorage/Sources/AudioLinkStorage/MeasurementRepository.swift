import AudioLinkCore
import Foundation

public protocol MeasurementRepository: Sendable {
    func saveSession(_ session: MeasurementHistorySession) async throws
    func saveSessions(_ sessions: [MeasurementHistorySession]) async throws
    func appendRun(_ run: MeasurementHistoryRun, toSession sessionID: UUID) async throws
    func updateRepeatedStatistics(
        sessionID: UUID,
        statistics: RepeatedMeasurementStatistics?,
        configurationPayload: Data,
        configurationSummary: [String: String],
        updatedAt: Date
    ) async throws
    func session(id: UUID) async throws -> MeasurementHistorySession?
    func run(id: UUID) async throws -> MeasurementHistoryRun?
    func runs(matching query: MeasurementHistoryQuery) async throws -> MeasurementHistoryPage
    func updateSession(id: UUID, name: String, notes: String) async throws
    func deleteRun(id: UUID) async throws
    func deleteRuns(ids: [UUID]) async throws
    func deleteSession(id: UUID) async throws
    func deleteAll() async throws
    func comparison(runIDs: [UUID]) async throws -> MeasurementRunComparison
    func saveCalibrationProfile(_ profile: CalibrationProfile) async throws
    func calibrationProfiles() async throws -> [CalibrationProfile]
    func calibrationProfile(id: UUID) async throws -> CalibrationProfile?
    func deleteCalibrationProfile(id: UUID) async throws
    func repositoryInfo() async throws -> MeasurementRepositoryInfo
    func saveLabArtifact(_ artifact: LabArtifactRecord) async throws
    func labArtifacts(kind: String?) async throws -> [LabArtifactRecord]
    func deleteLabArtifact(id: UUID) async throws
}

public extension MeasurementRepository {
    func updateRepeatedStatistics(
        sessionID: UUID,
        statistics: RepeatedMeasurementStatistics?,
        configurationPayload: Data,
        configurationSummary: [String: String],
        updatedAt: Date
    ) async throws {
        guard let existing = try await session(id: sessionID) else {
            throw MeasurementStorageError.recordNotFound(kind: "session", id: sessionID)
        }
        try await saveSession(
            MeasurementHistorySession(
                id: existing.id,
                createdAt: existing.createdAt,
                updatedAt: updatedAt,
                name: existing.name,
                notes: existing.notes,
                measurementType: existing.measurementType,
                savePolicy: existing.savePolicy,
                configurationPayload: configurationPayload,
                configurationSummary: configurationSummary,
                statistics: existing.statistics,
                repeatedStatistics: statistics,
                inputDevice: existing.inputDevice,
                outputDevice: existing.outputDevice,
                appVersion: existing.appVersion,
                algorithmVersion: existing.algorithmVersion,
                runs: existing.runs
            )
        )
    }
}

public enum MeasurementStorageError: Error, Codable, Equatable, Sendable {
    case unableToOpenDatabase(message: String)
    case corruptDatabase(message: String)
    case migrationFailed(fromVersion: Int, toVersion: Int, message: String)
    case transactionFailed(message: String)
    case constraintViolation(message: String)
    case encodingFailed(type: String, message: String)
    case decodingFailed(type: String, message: String)
    case queryFailed(operation: String, message: String)
    case invalidRecord(message: String)
    case recordNotFound(kind: String, id: UUID)

    public var userFacingDescription: String {
        switch self {
        case .unableToOpenDatabase:
            "Measurement history could not be opened."
        case .corruptDatabase:
            "Measurement history appears to be damaged and was not modified."
        case .migrationFailed:
            "Measurement history could not be upgraded safely."
        case .transactionFailed:
            "The history change could not be completed and was rolled back."
        case .constraintViolation, .invalidRecord:
            "The measurement record is incomplete or conflicts with existing history."
        case .encodingFailed, .decodingFailed:
            "A measurement record could not be converted to or from storage."
        case .queryFailed:
            "Measurement history could not be read or updated."
        case .recordNotFound:
            "The selected history record no longer exists."
        }
    }

    public var debugContext: String {
        switch self {
        case let .unableToOpenDatabase(message),
             let .corruptDatabase(message),
             let .transactionFailed(message),
             let .constraintViolation(message),
             let .invalidRecord(message):
            message
        case let .migrationFailed(fromVersion, toVersion, message):
            "migration \(fromVersion) -> \(toVersion): \(message)"
        case let .encodingFailed(type, message), let .decodingFailed(type, message):
            "\(type): \(message)"
        case let .queryFailed(operation, message):
            "\(operation): \(message)"
        case let .recordNotFound(kind, id):
            "\(kind) \(id.uuidString)"
        }
    }
}
