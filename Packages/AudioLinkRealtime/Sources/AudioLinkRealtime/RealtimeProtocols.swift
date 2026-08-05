import AudioLinkCore
import AudioLinkDSP
import Foundation

public protocol AudioDeviceService: Sendable {
    func devices() async throws -> [AudioDeviceDescription]
    func defaultInputDevice() async throws -> AudioDeviceDescription?
    func defaultOutputDevice() async throws -> AudioDeviceDescription?
    func validate(route: AudioRouteConfiguration) async throws
    func events() -> AsyncStream<AudioDeviceEvent>
}

public protocol MicrophonePermissionAuthorizing: Sendable {
    func status() async -> MicrophonePermissionStatus
    func requestPermission() async -> MicrophonePermissionStatus
}

public protocol PlaybackController: Sendable {
    func preparePlayback(signal: AudioSampleBuffer, route: AudioRouteConfiguration) async throws
    func playPreparedSignal() async throws -> PlaybackTiming
    func preview(signal: AudioSampleBuffer, route: AudioRouteConfiguration) async throws
    func stopPlayback() async
}

public protocol RecordingController: Sendable {
    func startRecording(
        route: AudioRouteConfiguration,
        maximumFrameCount: Int
    ) async throws -> RecordingStart
    func stopRecording() async throws -> RecordingCapture
    func cancelRecording() async
}

public protocol RealtimeMeasurementSaving: Sendable {
    func save(result: RealtimeMeasurementResult) async throws -> UUID?
}

public struct NoopRealtimeMeasurementSaver: RealtimeMeasurementSaving {
    public init() {}
    public func save(result: RealtimeMeasurementResult) async throws -> UUID? { nil }
}

public protocol RealtimeMeasurementRunning: Sendable {
    func measure(
        configuration: RealtimeMeasurementConfiguration,
        stateHandler: (@Sendable (RealtimeMeasurementState) -> Void)?
    ) async throws -> RealtimeMeasurementResult
    func preview(configuration: RealtimeMeasurementConfiguration) async throws
    func stop() async
}
