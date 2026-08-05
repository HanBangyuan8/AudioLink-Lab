import AudioLinkCore
import AudioLinkDSP
import Foundation

public struct AudioDeviceDescription: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let descriptor: DeviceDescriptor
    public let objectID: UInt32?
    public let nominalSampleRate: SampleRate
    public let inputChannelCount: Int
    public let outputChannelCount: Int
    public let isDefaultInput: Bool
    public let isDefaultOutput: Bool

    public init(
        descriptor: DeviceDescriptor,
        objectID: UInt32? = nil,
        nominalSampleRate: SampleRate,
        inputChannelCount: Int,
        outputChannelCount: Int,
        isDefaultInput: Bool = false,
        isDefaultOutput: Bool = false
    ) {
        self.descriptor = descriptor
        self.objectID = objectID
        self.nominalSampleRate = nominalSampleRate
        self.inputChannelCount = inputChannelCount
        self.outputChannelCount = outputChannelCount
        self.isDefaultInput = isDefaultInput
        self.isDefaultOutput = isDefaultOutput
    }

    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
}

public struct AudioRouteConfiguration: Codable, Equatable, Sendable {
    public let inputDevice: AudioDeviceDescription
    public let outputDevice: AudioDeviceDescription
    public let inputChannel: Int
    public let outputChannel: Int
    public let sampleRate: SampleRate
    public let bufferFrameCount: Int

    public init(
        inputDevice: AudioDeviceDescription,
        outputDevice: AudioDeviceDescription,
        inputChannel: Int = 0,
        outputChannel: Int = 0,
        sampleRate: SampleRate,
        bufferFrameCount: Int = 512
    ) {
        self.inputDevice = inputDevice
        self.outputDevice = outputDevice
        self.inputChannel = inputChannel
        self.outputChannel = outputChannel
        self.sampleRate = sampleRate
        self.bufferFrameCount = bufferFrameCount
    }
}

public enum AudioDeviceEvent: Codable, Equatable, Sendable {
    case disconnected(uid: String)
    case nominalSampleRateChanged(uid: String, oldValue: SampleRate, newValue: SampleRate)
    case defaultInputChanged(uid: String?)
    case defaultOutputChanged(uid: String?)
    case deviceListChanged
}

public enum MicrophonePermissionStatus: String, Codable, Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

public struct AudioEngineTimestamp: Codable, Equatable, Sendable {
    public let hostTime: UInt64
    public let sampleTime: Double?
    public let capturedAt: Date

    public init(hostTime: UInt64, sampleTime: Double? = nil, capturedAt: Date = Date()) {
        self.hostTime = hostTime
        self.sampleTime = sampleTime
        self.capturedAt = capturedAt
    }
}

public struct AudioRouteDiagnosticEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let occurredAt: Date
    public let description: String

    public init(id: UUID = UUID(), occurredAt: Date = Date(), description: String) {
        self.id = id
        self.occurredAt = occurredAt
        self.description = description
    }
}

public struct AudioEngineDiagnostics: Codable, Equatable, Sendable {
    public let engineStart: AudioEngineTimestamp?
    public let recordingStart: AudioEngineTimestamp?
    public let playbackScheduled: AudioEngineTimestamp?
    public let playbackCompletion: AudioEngineTimestamp?
    public let firstRecordedSampleTime: Double?
    public let lastRecordedSampleTime: Double?
    public let bufferFrameCount: Int
    public let recordedBufferCount: Int
    public let underflowCount: Int
    public let overflowCount: Int
    public let droppedBufferCount: Int
    public let routeChanges: [AudioRouteDiagnosticEvent]
    public let nominalSampleRate: SampleRate
    public let recordingBeganBeforePlayback: Bool
    public let notes: [String]

    public init(
        engineStart: AudioEngineTimestamp? = nil,
        recordingStart: AudioEngineTimestamp? = nil,
        playbackScheduled: AudioEngineTimestamp? = nil,
        playbackCompletion: AudioEngineTimestamp? = nil,
        firstRecordedSampleTime: Double? = nil,
        lastRecordedSampleTime: Double? = nil,
        bufferFrameCount: Int,
        recordedBufferCount: Int = 0,
        underflowCount: Int = 0,
        overflowCount: Int = 0,
        droppedBufferCount: Int = 0,
        routeChanges: [AudioRouteDiagnosticEvent] = [],
        nominalSampleRate: SampleRate,
        recordingBeganBeforePlayback: Bool = false,
        notes: [String] = []
    ) {
        self.engineStart = engineStart
        self.recordingStart = recordingStart
        self.playbackScheduled = playbackScheduled
        self.playbackCompletion = playbackCompletion
        self.firstRecordedSampleTime = firstRecordedSampleTime
        self.lastRecordedSampleTime = lastRecordedSampleTime
        self.bufferFrameCount = bufferFrameCount
        self.recordedBufferCount = recordedBufferCount
        self.underflowCount = underflowCount
        self.overflowCount = overflowCount
        self.droppedBufferCount = droppedBufferCount
        self.routeChanges = routeChanges
        self.nominalSampleRate = nominalSampleRate
        self.recordingBeganBeforePlayback = recordingBeganBeforePlayback
        self.notes = notes
    }
}

public struct PlaybackTiming: Codable, Equatable, Sendable {
    public let scheduled: AudioEngineTimestamp
    public let completed: AudioEngineTimestamp

    public init(scheduled: AudioEngineTimestamp, completed: AudioEngineTimestamp) {
        self.scheduled = scheduled
        self.completed = completed
    }
}

public struct RecordingStart: Codable, Equatable, Sendable {
    public let engineStart: AudioEngineTimestamp
    public let recordingStart: AudioEngineTimestamp

    public init(engineStart: AudioEngineTimestamp, recordingStart: AudioEngineTimestamp) {
        self.engineStart = engineStart
        self.recordingStart = recordingStart
    }
}

public struct RecordingCapture: Equatable, Sendable {
    public let audio: AudioSampleBuffer
    public let diagnostics: AudioEngineDiagnostics

    public init(audio: AudioSampleBuffer, diagnostics: AudioEngineDiagnostics) {
        self.audio = audio
        self.diagnostics = diagnostics
    }
}

public struct RealtimeMeasurementConfiguration: Codable, Equatable, Sendable {
    public let route: AudioRouteConfiguration
    public let signal: TestSignalConfiguration
    public let preRoll: DurationSeconds
    public let postRoll: DurationSeconds
    public let correlation: CorrelationConfiguration
    public let preprocessing: PreprocessingConfiguration
    /// Stable ID shared by every run in a repeated plan. Nil for a standalone run.
    public let measurementGroupID: UUID?
    public let planRunSequence: Int?
    public let isWarmUpRun: Bool
    public let calibrationProfile: CalibrationProfile?
    public let applyCalibrationOffset: Bool

    public init(
        route: AudioRouteConfiguration,
        signal: TestSignalConfiguration,
        preRoll: DurationSeconds,
        postRoll: DurationSeconds,
        correlation: CorrelationConfiguration,
        preprocessing: PreprocessingConfiguration = .none,
        measurementGroupID: UUID? = nil,
        planRunSequence: Int? = nil,
        isWarmUpRun: Bool = false,
        calibrationProfile: CalibrationProfile? = nil,
        applyCalibrationOffset: Bool = false
    ) {
        self.route = route
        self.signal = signal
        self.preRoll = preRoll
        self.postRoll = postRoll
        self.correlation = correlation
        self.preprocessing = preprocessing
        self.measurementGroupID = measurementGroupID
        self.planRunSequence = planRunSequence
        self.isWarmUpRun = isWarmUpRun
        self.calibrationProfile = calibrationProfile
        self.applyCalibrationOffset = applyCalibrationOffset
    }
}

public struct RealtimeMeasurementResult: Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let completedAt: Date
    public let configuration: RealtimeMeasurementConfiguration
    public let generatedSignal: GeneratedSignal
    public let preparedReference: ImportedAudioFile
    public let preparedRecording: ImportedAudioFile
    public let assessment: QualityAssessedMeasurement
    public let diagnostics: AudioEngineDiagnostics
    public let savedHistorySessionID: UUID?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        completedAt: Date,
        configuration: RealtimeMeasurementConfiguration,
        generatedSignal: GeneratedSignal,
        preparedReference: ImportedAudioFile,
        preparedRecording: ImportedAudioFile,
        assessment: QualityAssessedMeasurement,
        diagnostics: AudioEngineDiagnostics,
        savedHistorySessionID: UUID? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.configuration = configuration
        self.generatedSignal = generatedSignal
        self.preparedReference = preparedReference
        self.preparedRecording = preparedRecording
        self.assessment = assessment
        self.diagnostics = diagnostics
        self.savedHistorySessionID = savedHistorySessionID
    }

    public func withSavedHistorySessionID(_ id: UUID?) -> Self {
        Self(
            id: self.id,
            startedAt: startedAt,
            completedAt: completedAt,
            configuration: configuration,
            generatedSignal: generatedSignal,
            preparedReference: preparedReference,
            preparedRecording: preparedRecording,
            assessment: assessment,
            diagnostics: diagnostics,
            savedHistorySessionID: id
        )
    }
}

public enum RealtimeMeasurementState: Equatable, Sendable {
    case idle
    case validatingDevices
    case requestingPermission
    case preparingSignal
    case startingRecording
    case preRoll
    case playing
    case postRoll
    case preprocessing
    case analyzing
    case saving
    case completed
    case failed(RealtimeMeasurementFailure)
    case cancelled

    public var isBusy: Bool {
        switch self {
        case .validatingDevices, .requestingPermission, .preparingSignal, .startingRecording,
             .preRoll, .playing, .postRoll, .preprocessing, .analyzing, .saving:
            true
        default:
            false
        }
    }
}

public enum RealtimeMeasurementFailureCode: String, Codable, Sendable {
    case permissionDenied
    case inputDeviceUnavailable
    case outputDeviceUnavailable
    case deviceDisconnected
    case sampleRateMismatch
    case invalidChannel
    case incompatibleRoute
    case signalGenerationFailed
    case engineStartFailed
    case playbackFailed
    case recordingFailed
    case analysisFailed
    case saveFailed
    case alreadyRunning
    case cancelled
}

public struct RealtimeMeasurementFailure: Error, Codable, Equatable, Sendable {
    public let code: RealtimeMeasurementFailureCode
    public let userMessage: String
    public let recoverySuggestion: String
    public let technicalContext: String?

    public init(
        code: RealtimeMeasurementFailureCode,
        userMessage: String,
        recoverySuggestion: String,
        technicalContext: String? = nil
    ) {
        self.code = code
        self.userMessage = userMessage
        self.recoverySuggestion = recoverySuggestion
        self.technicalContext = technicalContext
    }
}
