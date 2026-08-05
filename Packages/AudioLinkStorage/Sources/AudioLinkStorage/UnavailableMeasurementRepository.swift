import AudioLinkCore
import Foundation

public actor UnavailableMeasurementRepository: MeasurementRepository {
    private let error: MeasurementStorageError

    public init(error: MeasurementStorageError) {
        self.error = error
    }

    public func saveSession(_ session: MeasurementHistorySession) throws { throw error }
    public func saveSessions(_ sessions: [MeasurementHistorySession]) throws { throw error }
    public func appendRun(_ run: MeasurementHistoryRun, toSession sessionID: UUID) throws { throw error }
    public func session(id: UUID) throws -> MeasurementHistorySession? { throw error }
    public func run(id: UUID) throws -> MeasurementHistoryRun? { throw error }
    public func runs(matching query: MeasurementHistoryQuery) throws -> MeasurementHistoryPage { throw error }
    public func updateSession(id: UUID, name: String, notes: String) throws { throw error }
    public func deleteRun(id: UUID) throws { throw error }
    public func deleteRuns(ids: [UUID]) throws { throw error }
    public func deleteSession(id: UUID) throws { throw error }
    public func deleteAll() throws { throw error }
    public func comparison(runIDs: [UUID]) throws -> MeasurementRunComparison { throw error }
    public func saveCalibrationProfile(_ profile: CalibrationProfile) throws { throw error }
    public func calibrationProfiles() throws -> [CalibrationProfile] { throw error }
    public func calibrationProfile(id: UUID) throws -> CalibrationProfile? { throw error }
    public func deleteCalibrationProfile(id: UUID) throws { throw error }
    public func repositoryInfo() throws -> MeasurementRepositoryInfo { throw error }
    public func saveLabArtifact(_ artifact: LabArtifactRecord) throws { throw error }
    public func labArtifacts(kind: String?) throws -> [LabArtifactRecord] { throw error }
    public func deleteLabArtifact(id: UUID) throws { throw error }
}
