import AudioLinkCore
import AudioLinkRealtime
import AudioLinkStorage
import Foundation

struct AudioLinkDependencies: Sendable {
    let sessionStore: any MeasurementSessionStore
    let measurementRepository: any MeasurementRepository
    let historyAudioContainerURL: URL?
    let measurementPerformer: any MeasurementPerforming
    let realtimeDeviceService: any AudioDeviceService
    let realtimeMeasurementRunner: any RealtimeMeasurementRunning
    let repeatedMeasurementController: any RepeatedMeasurementControlling
    let longTermStabilityController: any LongTermStabilityControlling

    static func live() -> Self {
        let repository: any MeasurementRepository
        let containerURL: URL?
        do {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let root = applicationSupport.appendingPathComponent("AudioLink Lab", isDirectory: true)
            repository = try SQLiteMeasurementRepository(
                databaseURL: root.appendingPathComponent("History.sqlite")
            )
            containerURL = root
        } catch let storageError as MeasurementStorageError {
            repository = UnavailableMeasurementRepository(error: storageError)
            containerURL = nil
        } catch {
            repository = UnavailableMeasurementRepository(
                error: .unableToOpenDatabase(message: error.localizedDescription)
            )
            containerURL = nil
        }
        let deviceService = SystemAudioDeviceService()
        let ioController = AVAudioEngineRealtimeController()
        let realtimeEngine = RealtimeMeasurementEngine(
            deviceService: deviceService,
            permissionAuthorizer: SystemMicrophonePermissionAuthorizer(),
            playbackController: ioController,
            recordingController: ioController,
            saver: LiveRealtimeMeasurementHistoryPersistence(repository: repository)
        )
        let repeatedController = RepeatedMeasurementController(
            runner: realtimeEngine,
            deviceService: deviceService,
            progressSaver: RepeatedMeasurementHistoryPersistence(repository: repository)
        )
        let longTermController = LongTermStabilityController(
            runner: realtimeEngine,
            deviceService: deviceService
        )
        return Self(
            sessionStore: SQLiteMeasurementSessionStore(repository: repository),
            measurementRepository: repository,
            historyAudioContainerURL: containerURL,
            measurementPerformer: FoundationMeasurementPerformer(),
            realtimeDeviceService: deviceService,
            realtimeMeasurementRunner: realtimeEngine,
            repeatedMeasurementController: repeatedController,
            longTermStabilityController: longTermController
        )
    }
}

private struct FoundationMeasurementPerformer: MeasurementPerforming {
    func measure(configuration: MeasurementConfiguration) async throws -> MeasurementRun {
        try Task.checkCancellation()
        throw MeasurementError.audioEngineFailure(
            ErrorContext(
                diagnosticMessage: "Legacy interval monitoring is not connected to hardware. Use New Measurement › Real-time for AVAudioEngine playback, capture, correlation, and history.",
                metadata: [
                    "sampleRateHz": String(configuration.format.sampleRate.hertz),
                    "signal": configuration.signal.rawValue
                ]
            )
        )
    }
}
