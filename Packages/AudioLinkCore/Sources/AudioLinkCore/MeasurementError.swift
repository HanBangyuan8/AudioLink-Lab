import Foundation

public struct ErrorContext: Codable, Equatable, Sendable {
    public let underlyingType: String?
    public let diagnosticMessage: String
    public let metadata: [String: String]

    public init(
        underlyingType: String? = nil,
        diagnosticMessage: String,
        metadata: [String: String] = [:]
    ) {
        self.underlyingType = underlyingType
        self.diagnosticMessage = diagnosticMessage
        self.metadata = metadata
    }

    public init(error: any Error, metadata: [String: String] = [:]) {
        underlyingType = String(reflecting: type(of: error))
        diagnosticMessage = String(describing: error)
        self.metadata = metadata
    }
}

public enum MeasurementError: Error, Codable, Equatable, Sendable {
    case invalidConfiguration(ErrorContext)
    case audioDeviceUnavailable(ErrorContext)
    case audioEngineFailure(ErrorContext)
    case insufficientSignal(ErrorContext)
    case correlationFailure(ErrorContext)
    case storageFailure(ErrorContext)
    case networkingUnavailable(ErrorContext)
    case cancelled(ErrorContext)

    public var userFacingDescription: String {
        switch self {
        case .invalidConfiguration: "The measurement configuration is invalid."
        case .audioDeviceUnavailable: "The selected audio device is unavailable."
        case .audioEngineFailure: "Audio playback or recording could not be completed."
        case .insufficientSignal: "The recorded signal is too weak for a reliable measurement."
        case .correlationFailure: "A reliable correlation peak could not be found."
        case .storageFailure: "The measurement could not be saved."
        case .networkingUnavailable: "Network measurement is not available."
        case .cancelled: "The measurement was cancelled."
        }
    }

    public var debugContext: ErrorContext {
        switch self {
        case let .invalidConfiguration(context),
             let .audioDeviceUnavailable(context),
             let .audioEngineFailure(context),
             let .insufficientSignal(context),
             let .correlationFailure(context),
             let .storageFailure(context),
             let .networkingUnavailable(context),
             let .cancelled(context):
            context
        }
    }
}

extension MeasurementError: LocalizedError {
    public var errorDescription: String? { userFacingDescription }
    public var failureReason: String? { debugContext.diagnosticMessage }
}

