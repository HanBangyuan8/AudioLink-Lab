import AudioLinkCore
import Foundation

public enum AudioLinkNetworkRole: String, Codable, CaseIterable, Sendable {
    case coordinator
    case companion
}

public struct AudioLinkNetworkingCapabilities: Equatable, Sendable {
    public let supportsDiscovery: Bool
    public let supportsClockSynchronization: Bool
    public let supportsAudioTransport: Bool

    public static let foundationMilestone = AudioLinkNetworkingCapabilities(
        supportsDiscovery: true,
        supportsClockSynchronization: true,
        // v1 transfers recorded files; it intentionally does not stream live PCM.
        supportsAudioTransport: false
    )

    public init(
        supportsDiscovery: Bool,
        supportsClockSynchronization: Bool,
        supportsAudioTransport: Bool
    ) {
        self.supportsDiscovery = supportsDiscovery
        self.supportsClockSynchronization = supportsClockSynchronization
        self.supportsAudioTransport = supportsAudioTransport
    }
}
