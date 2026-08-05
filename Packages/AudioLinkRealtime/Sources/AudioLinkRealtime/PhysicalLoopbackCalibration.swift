import AudioLinkCore
import Foundation

public enum PhysicalLoopbackCalibrationError: Error, LocalizedError, Equatable, Sendable {
    case noUsableDelay

    public var errorDescription: String? {
        "The physical loopback calibration did not produce a usable delay estimate."
    }
}

/// Runs one normal correlation measurement and turns its raw result into a
/// route-specific profile. The caller still owns saving the profile, so a
/// failed or cancelled calibration cannot overwrite an existing profile.
public struct PhysicalLoopbackCalibrator: Sendable {
    private let runner: any RealtimeMeasurementRunning

    public init(runner: any RealtimeMeasurementRunning) {
        self.runner = runner
    }

    public func measure(
        configuration: RealtimeMeasurementConfiguration,
        profileName: String,
        notes: String = ""
    ) async throws -> CalibrationProfile {
        var uncalibrated = configuration
        uncalibrated = RealtimeMeasurementConfiguration(
            route: configuration.route,
            signal: configuration.signal,
            preRoll: configuration.preRoll,
            postRoll: configuration.postRoll,
            correlation: configuration.correlation,
            preprocessing: configuration.preprocessing,
            measurementGroupID: configuration.measurementGroupID,
            planRunSequence: configuration.planRunSequence,
            isWarmUpRun: configuration.isWarmUpRun
        )
        let result = try await runner.measure(configuration: uncalibrated, stateHandler: nil)
        guard let delay = result.assessment.delay else { throw PhysicalLoopbackCalibrationError.noUsableDelay }
        return CalibrationProfile(
            profileName: profileName,
            inputDevice: configuration.route.inputDevice.descriptor,
            outputDevice: configuration.route.outputDevice.descriptor,
            channelMapping: CalibrationChannelMapping(inputChannel: configuration.route.inputChannel, outputChannel: configuration.route.outputChannel),
            sampleRate: configuration.route.sampleRate,
            bufferFrameCount: configuration.route.bufferFrameCount,
            knownFixedDelay: CalibrationOffset(sampleCount: delay.sampleOffset, sampleRate: delay.sampleRate),
            notes: notes,
            confidence: min(1, max(0, result.assessment.quality.confidence.value)),
            calibrationMethod: .physicalLoopback
        )
    }
}
