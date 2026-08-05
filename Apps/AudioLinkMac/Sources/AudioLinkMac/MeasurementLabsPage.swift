import AudioLinkAdaptive
import AudioLinkCore
import SwiftUI

struct MeasurementLabsPage: View {
    @State private var objective: MeasurementObjective = .balanced
    @State private var plan: AdaptivePlan?
    @State private var plannerMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Measurement Labs").font(.largeTitle.weight(.semibold))
                Text("Deterministic planning, spatial IR, and distributed-session foundations. Hardware and room capture remain explicit user actions.")
                    .foregroundStyle(.secondary)
                GroupBox("Adaptive Measurement Planner") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Objective", selection: $objective) {
                            ForEach(MeasurementObjective.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.menu)
                        Button("Preview plan") { previewPlan() }
                            .keyboardShortcut(.return, modifiers: [.command])
                        if let plan {
                            LabeledContent("Signal", value: plan.decision.signalConfiguration.kind.rawValue)
                            LabeledContent("Duration", value: String(format: "%.2f s", plan.decision.signalConfiguration.duration.value))
                            LabeledContent("Amplitude", value: String(format: "%.3f", plan.decision.signalConfiguration.amplitude))
                            LabeledContent("Search", value: "\(plan.decision.searchRange.lowerBound)…\(plan.decision.searchRange.upperBound) samples")
                            LabeledContent("Planner confidence", value: plan.diagnostics.confidence.rawValue)
                            ForEach(plan.decision.reasons) { reason in
                                Text("• \(reason.rule.id): \(reason.outcome)").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if let plannerMessage { Text(plannerMessage).foregroundStyle(.secondary).font(.footnote) }
                    }.padding(4)
                }
                GroupBox("Spatial Impulse Response Mapper") {
                    Text("Projects, coordinates, validity-aware EDT/RT20/RT30/RT60, clarity metrics, and sparse inverse-distance maps are available through AudioLinkSpatial. No room geometry or microphone calibration is inferred here.")
                        .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.secondary).padding(4)
                }
                GroupBox("Distributed Measurement Network") {
                    Text("The coordinator requires every assigned node to be ready. RTT, clock offset, drift, scheduling, callback, and acoustic uncertainty remain separate; network timestamps never replace correlation.")
                        .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.secondary).padding(4)
                }
            }.padding(24)
        }.background(Color(nsColor: .windowBackgroundColor)).accessibilityElement(children: .contain)
    }

    private func previewPlan() {
        do { plan = try AdaptiveMeasurementPlanner().plan(objective: objective, environment: MeasurementEnvironment(sampleRate: .hz48000)); plannerMessage = nil }
        catch { plan = nil; plannerMessage = error.localizedDescription }
    }
}
