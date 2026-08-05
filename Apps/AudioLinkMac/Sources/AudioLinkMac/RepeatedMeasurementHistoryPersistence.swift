import AudioLinkCore
import AudioLinkRealtime
import AudioLinkStorage
import Foundation

/// Persists failure outcomes and the evolving aggregate. Successful outcomes
/// are inserted by `LiveRealtimeMeasurementHistoryPersistence` as part of the
/// single-run engine save stage, so every scheduled step has one durable row.
actor RepeatedMeasurementHistoryPersistence: RepeatedMeasurementProgressSaving {
    private let repository: any MeasurementRepository

    init(repository: any MeasurementRepository) {
        self.repository = repository
    }

    func record(
        outcome: RunOutcome,
        plan: MeasurementPlan,
        baseConfiguration: RealtimeMeasurementConfiguration,
        statistics: RepeatedMeasurementStatistics?
    ) async throws {
        if !outcome.succeeded {
            try await persistFailure(
                outcome,
                plan: plan,
                baseConfiguration: baseConfiguration
            )
        }
        try await repository.updateRepeatedStatistics(
            sessionID: plan.id,
            statistics: statistics,
            configurationPayload: try encodedPlan(plan),
            configurationSummary: configurationSummary(plan, route: baseConfiguration.route),
            updatedAt: outcome.completedAt
        )
    }

    private func persistFailure(
        _ outcome: RunOutcome,
        plan: MeasurementPlan,
        baseConfiguration: RealtimeMeasurementConfiguration
    ) async throws {
        let run = failureRun(outcome, plan: plan, base: baseConfiguration)
        if try await repository.session(id: plan.id) != nil {
            try await repository.appendRun(run, toSession: plan.id)
            return
        }
        let payload = try encodedPlan(plan)
        let route = baseConfiguration.route
        let session = MeasurementHistorySession(
            id: plan.id,
            createdAt: outcome.startedAt,
            updatedAt: outcome.completedAt,
            name: "Repeated: \(route.outputDevice.name) → \(route.inputDevice.name)",
            notes: "Repeated real-time measurement. Raw audio is not retained.",
            measurementType: .liveAudio,
            savePolicy: .resultsOnly,
            configurationPayload: payload,
            configurationSummary: configurationSummary(plan, route: route),
            inputDevice: route.inputDevice.descriptor,
            outputDevice: route.outputDevice.descriptor,
            appVersion: appVersion,
            algorithmVersion: LiveRealtimeMeasurementHistoryPersistence.algorithmVersion,
            runs: [run]
        )
        try await repository.saveSession(session)
    }

    private func failureRun(
        _ outcome: RunOutcome,
        plan: MeasurementPlan,
        base: RealtimeMeasurementConfiguration
    ) -> MeasurementHistoryRun {
        let format = AudioFormatDescriptor(
            sampleRate: base.route.sampleRate,
            channelCount: 1,
            bitDepth: 32,
            isInterleaved: false
        )
        let failure = outcome.failure?.failure
        let reference = placeholderFile(
            role: .reference,
            fileName: "Generated \(plan.signalKind.rawValue)",
            format: format
        )
        let recording = placeholderFile(
            role: .recording,
            fileName: "Failed realtime capture",
            format: format
        )
        return MeasurementHistoryRun(
            id: outcome.id,
            sessionID: plan.id,
            createdAt: outcome.startedAt,
            completedAt: outcome.completedAt,
            referenceFile: reference,
            recordingFile: recording,
            delayEstimate: nil,
            correlation: nil,
            quality: invalidQuality(failure),
            chartCache: StoredChartCacheMetadata(
                correlationSequenceAvailable: false,
                correlationSampleCount: 0,
                waveformAvailable: false,
                waveformUnavailableReason: "This run failed before chart data was produced."
            ),
            notes: failure.map {
                "Step \(outcome.scheduledStepIndex) failed [\($0.code.rawValue)]: \($0.userMessage)"
            } ?? "Step \(outcome.scheduledStepIndex) failed."
        )
    }

    private func placeholderFile(
        role: StoredFileRole,
        fileName: String,
        format: AudioFormatDescriptor
    ) -> StoredAudioFileMetadata {
        StoredAudioFileMetadata(
            role: role,
            privacyIdentifier: UUID().uuidString,
            fileName: fileName,
            container: "realtime",
            encoding: "float32",
            format: format,
            frameCount: 0,
            durationSeconds: 0,
            peakMagnitude: 0,
            rootMeanSquare: 0,
            clippingSampleCount: 0,
            dcOffset: 0
        )
    }

    private func invalidQuality(_ failure: RealtimeMeasurementFailure?) -> MeasurementQuality {
        let message = failure?.userMessage ?? "This run did not complete."
        return MeasurementQuality(
            level: .invalid,
            confidence: ConfidenceScore(value: 0, components: []),
            summary: message,
            metrics: [],
            issues: [
                QualityIssue(
                    code: .analysisUnavailable,
                    severity: .fatal,
                    userDescription: message,
                    technicalDescription: failure?.technicalContext ?? "No result was produced.",
                    recommendedAction: failure?.recoverySuggestion ?? "Check the route and repeat the run."
                )
            ],
            peakAmbiguity: PeakAmbiguity(
                candidates: [],
                primaryToSecondaryRatio: nil,
                hasSimilarPeaks: false,
                peakSpacings: [],
                periodicInterval: nil,
                explanation: "Peak analysis was unavailable."
            ),
            signal: SignalQualityAnalysis(
                referenceRMS: 0,
                observedRMS: 0,
                signalToNoiseDecibels: nil,
                clippingRatio: 0,
                dcOffsetMagnitude: 0,
                referenceCoverageRatio: nil,
                isPolarityInverted: nil,
                appearsTruncated: false,
                channelsConsistent: nil,
                channelDelaySpreadSamples: nil,
                channelPeakSpread: nil
            ),
            delayDiagnostics: DelayEstimateDiagnostics(
                selectedDelay: nil,
                candidatePeaks: [],
                peakWidthSamples: nil,
                localPeakSharpness: nil,
                searchBoundaryDistance: nil,
                channelResults: []
            ),
            shouldRemeasure: true
        )
    }

    private func encodedPlan(_ plan: MeasurementPlan) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(plan)
        } catch {
            throw MeasurementStorageError.encodingFailed(
                type: "MeasurementPlan",
                message: error.localizedDescription
            )
        }
    }

    private func configurationSummary(
        _ plan: MeasurementPlan,
        route: AudioRouteConfiguration
    ) -> [String: String] {
        [
            "measurementMode": "repeated",
            "runCount": String(plan.runCount),
            "warmUpRuns": String(plan.warmUpRuns),
            "discardWarmUp": String(plan.discardWarmUp),
            "sampleRate": String(route.sampleRate.hertz),
            "signalKind": plan.signalKind.rawValue,
            "seedPolicy": plan.randomSeedPolicy.rawValue,
            "inputDevice": route.inputDevice.name,
            "outputDevice": route.outputDevice.name,
            "outlierMethod": plan.outlierMethod.rawValue,
            "outlierThreshold": String(plan.outlierThreshold)
        ]
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
}
