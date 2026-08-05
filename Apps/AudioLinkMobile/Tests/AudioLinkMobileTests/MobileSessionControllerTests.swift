import AudioLinkCore
import AudioLinkNetworking
import Foundation
import Testing
@testable import AudioLinkMobile

@MainActor
struct MobileSessionControllerTests {
    @Test func identityAdvertisesControllerRecorderAndPlayerRoles() {
        let identity = MobileIdentityFactory.make()
        #expect(identity.roles.contains(.controller))
        #expect(identity.roles.contains(.recorder))
        #expect(identity.roles.contains(.player))
    }

    @Test func stateLabelsAndBusyStateAreDeterministic() {
        let error = MobileError.cancelled
        #expect(MobileMeasurementState.idle.label == "Idle")
        #expect(MobileMeasurementState.running.isActive)
        #expect(!MobileMeasurementState.cancelled.isActive)
        #expect(MobileMeasurementState.failed(error).label == "Failed")
    }

    @Test func startPlanRoundTripsWithExplicitSchedulingFields() throws {
        let plan = MobileStartPlan(
            role: .recorder,
            sampleRateHertz: 48_000,
            scheduledAfterNanoseconds: 900_000_000,
            localHostTimeNanoseconds: 123,
            retainRecording: true
        )
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(MobileStartPlan.self, from: data)
        #expect(decoded == plan)
        #expect(decoded.scheduledAfterNanoseconds == 900_000_000)
        #expect(decoded.retainRecording)
    }

    @Test func mobileErrorHasRecoveryOrBoundaryMessage() {
        #expect(MobileError.microphonePermissionDenied.localizedDescription.contains("Settings"))
        #expect(MobileError.localNetworkPermissionRequired.localizedDescription.contains("Local Network"))
        #expect(MobileError.transferFailure("checksum").localizedDescription.contains("checksum"))
    }
}
