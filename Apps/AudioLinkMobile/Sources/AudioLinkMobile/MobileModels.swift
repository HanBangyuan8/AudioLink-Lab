import AudioLinkCore
import AudioLinkDSP
import AudioLinkNetworking
import Foundation

public enum MobileMeasurementState: Equatable, Sendable {
    case idle
    case discovering
    case pairing(PeerIdentity)
    case negotiating
    case paired
    case preparing
    case ready
    case running
    case transferring
    case completed(MobileMeasurementSummary)
    case interrupted(String)
    case cancelled
    case failed(MobileError)

    public var label: String {
        switch self {
        case .idle: "Idle"
        case .discovering: "Searching nearby devices"
        case .pairing: "Pairing"
        case .negotiating: "Negotiating session"
        case .paired: "Paired"
        case .preparing: "Preparing audio"
        case .ready: "Ready"
        case .running: "Measuring"
        case .transferring: "Transferring recording"
        case .completed: "Completed"
        case .interrupted: "Interrupted"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }

    public var isActive: Bool {
        switch self {
        case .pairing, .negotiating, .preparing, .ready, .running, .transferring: true
        default: false
        }
    }
}

public enum MobileMicrophonePermission: String, Codable, CaseIterable, Sendable {
    case authorized
    case denied
    case notDetermined
    case unavailable

    public var label: String {
        switch self {
        case .authorized: "Allowed"
        case .denied: "Denied"
        case .notDetermined: "Not requested"
        case .unavailable: "Unavailable on this platform"
        }
    }
}

public struct MobileRouteSnapshot: Codable, Equatable, Sendable {
    public let inputName: String?
    public let outputName: String?
    public let inputPortType: String?
    public let outputPortType: String?
    public let sampleRateHertz: Double
    public let inputChannelCount: Int
    public let outputChannelCount: Int
    public let ioBufferDurationSeconds: Double
    public let supportsBluetooth: Bool
    public let isSpeakerOutput: Bool
    public let capturedAt: Date

    public init(
        inputName: String? = nil,
        outputName: String? = nil,
        inputPortType: String? = nil,
        outputPortType: String? = nil,
        sampleRateHertz: Double,
        inputChannelCount: Int,
        outputChannelCount: Int,
        ioBufferDurationSeconds: Double,
        supportsBluetooth: Bool,
        isSpeakerOutput: Bool,
        capturedAt: Date = Date()
    ) {
        self.inputName = inputName
        self.outputName = outputName
        self.inputPortType = inputPortType
        self.outputPortType = outputPortType
        self.sampleRateHertz = sampleRateHertz
        self.inputChannelCount = inputChannelCount
        self.outputChannelCount = outputChannelCount
        self.ioBufferDurationSeconds = ioBufferDurationSeconds
        self.supportsBluetooth = supportsBluetooth
        self.isSpeakerOutput = isSpeakerOutput
        self.capturedAt = capturedAt
    }
}

public struct MobileNetworkDiagnostics: Codable, Equatable, Sendable {
    public let lastRoundTripNanoseconds: UInt64?
    public let lastHeartbeatAt: Date?
    public let reconnectCount: Int
    public let messagesReceived: Int
    public let messagesSent: Int

    public init(
        lastRoundTripNanoseconds: UInt64? = nil,
        lastHeartbeatAt: Date? = nil,
        reconnectCount: Int = 0,
        messagesReceived: Int = 0,
        messagesSent: Int = 0
    ) {
        self.lastRoundTripNanoseconds = lastRoundTripNanoseconds
        self.lastHeartbeatAt = lastHeartbeatAt
        self.reconnectCount = reconnectCount
        self.messagesReceived = messagesReceived
        self.messagesSent = messagesSent
    }
}

public struct MobileAudioDiagnostics: Codable, Equatable, Sendable {
    public let engineStartHostTime: UInt64?
    public let recordingStartHostTime: UInt64?
    public let playbackStartHostTime: UInt64?
    public let firstSampleTime: Double?
    public let lastSampleTime: Double?
    public let recordedFrameCount: Int
    public let bufferFrameCount: Int
    public let routeChangeCount: Int
    public let interruptionCount: Int
    public let notes: [String]

    public init(
        engineStartHostTime: UInt64? = nil,
        recordingStartHostTime: UInt64? = nil,
        playbackStartHostTime: UInt64? = nil,
        firstSampleTime: Double? = nil,
        lastSampleTime: Double? = nil,
        recordedFrameCount: Int = 0,
        bufferFrameCount: Int = 0,
        routeChangeCount: Int = 0,
        interruptionCount: Int = 0,
        notes: [String] = []
    ) {
        self.engineStartHostTime = engineStartHostTime
        self.recordingStartHostTime = recordingStartHostTime
        self.playbackStartHostTime = playbackStartHostTime
        self.firstSampleTime = firstSampleTime
        self.lastSampleTime = lastSampleTime
        self.recordedFrameCount = recordedFrameCount
        self.bufferFrameCount = bufferFrameCount
        self.routeChangeCount = routeChangeCount
        self.interruptionCount = interruptionCount
        self.notes = notes
    }

    public func addingNote(_ note: String) -> Self {
        Self(
            engineStartHostTime: engineStartHostTime,
            recordingStartHostTime: recordingStartHostTime,
            playbackStartHostTime: playbackStartHostTime,
            firstSampleTime: firstSampleTime,
            lastSampleTime: lastSampleTime,
            recordedFrameCount: recordedFrameCount,
            bufferFrameCount: bufferFrameCount,
            routeChangeCount: routeChangeCount,
            interruptionCount: interruptionCount,
            notes: notes + [note]
        )
    }
}

public struct MobileMeasurementSummary: Codable, Equatable, Sendable {
    public let runID: UUID
    public let role: PeerRole
    public let sampleRateHertz: Double
    public let recordingFileName: String?
    public let rawDelaySamples: Double?
    public let rawDelayMilliseconds: Double?
    public let quality: String?
    public let diagnostics: MobileAudioDiagnostics

    public init(
        runID: UUID,
        role: PeerRole,
        sampleRateHertz: Double,
        recordingFileName: String? = nil,
        rawDelaySamples: Double? = nil,
        rawDelayMilliseconds: Double? = nil,
        quality: String? = nil,
        diagnostics: MobileAudioDiagnostics = .init()
    ) {
        self.runID = runID
        self.role = role
        self.sampleRateHertz = sampleRateHertz
        self.recordingFileName = recordingFileName
        self.rawDelaySamples = rawDelaySamples
        self.rawDelayMilliseconds = rawDelayMilliseconds
        self.quality = quality
        self.diagnostics = diagnostics
    }
}

public struct MobileStartPlan: Codable, Equatable, Sendable {
    public let runID: UUID
    public let role: PeerRole
    public let signal: SignalKind
    public let sampleRateHertz: Double
    public let durationSeconds: Double
    public let preRollSeconds: Double
    public let postRollSeconds: Double
    public let scheduledAfterNanoseconds: UInt64
    public let localHostTimeNanoseconds: UInt64
    public let retainRecording: Bool

    public init(
        runID: UUID = UUID(),
        role: PeerRole,
        signal: SignalKind = .logarithmicSweep,
        sampleRateHertz: Double,
        durationSeconds: Double = 1,
        preRollSeconds: Double = 0.25,
        postRollSeconds: Double = 0.5,
        scheduledAfterNanoseconds: UInt64 = 750_000_000,
        localHostTimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        retainRecording: Bool = false
    ) {
        self.runID = runID
        self.role = role
        self.signal = signal
        self.sampleRateHertz = sampleRateHertz
        self.durationSeconds = durationSeconds
        self.preRollSeconds = preRollSeconds
        self.postRollSeconds = postRollSeconds
        self.scheduledAfterNanoseconds = scheduledAfterNanoseconds
        self.localHostTimeNanoseconds = localHostTimeNanoseconds
        self.retainRecording = retainRecording
    }
}

public enum MobileRecordingRetentionPolicy: String, Codable, CaseIterable, Sendable {
    case deleteAfterTransfer
    case keepUntilUserDeletes
    case neverTransfer
}

public enum MobileError: Error, Codable, Equatable, LocalizedError, Sendable {
    case microphonePermissionDenied
    case localNetworkPermissionRequired
    case audioSessionConfigurationFailed(String)
    case audioRouteUnavailable(String)
    case audioInterrupted(String)
    case unsupportedRole(PeerRole)
    case protocolFailure(String)
    case transferFailure(String)
    case analysisUnavailable(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: "Microphone access is denied. Enable it in Settings › Privacy & Security › Microphone."
        case .localNetworkPermissionRequired: "Local Network access is required to discover and pair with AudioLink Lab."
        case let .audioSessionConfigurationFailed(message): "The iPhone audio session could not be configured. " + message
        case let .audioRouteUnavailable(message): "The selected iPhone audio route is unavailable. " + message
        case let .audioInterrupted(message): "The audio session was interrupted. " + message
        case let .unsupportedRole(role): "The iPhone cannot perform the " + role.rawValue + " role with the current route."
        case let .protocolFailure(message): "The paired-device session failed. " + message
        case let .transferFailure(message): "The recording transfer failed. " + message
        case let .analysisUnavailable(message): "The Mac could not complete the final analysis. " + message
        case .cancelled: "The measurement was cancelled."
        }
    }
}
