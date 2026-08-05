import Foundation

/// Version identifiers written into persisted results and exported reports.
///
/// These values are intentionally independent: changing the UI build does not
/// silently change the DSP algorithm, wire protocol, report schema, or SQLite
/// schema. Release tooling may override the app/build values in the bundle,
/// but persisted development results always have deterministic defaults.
public enum AudioLinkReleaseMetadata: Sendable {
    public static let appVersion = "1.0.0"
    public static let buildVersion = "1"
    /// Bumped after the independent DSP review changed spatial decay metrics,
    /// acoustic coverage semantics, and phase unwrapping in plugin analysis.
    /// Existing stored results retain their original version string.
    public static let algorithmVersion = "correlation-v2-dsp-audit"
    public static let adaptivePlannerVersion = "adaptive-rules-v1"
    public static let spatialAlgorithmVersion = "spatial-ir-schroeder-v2"
    public static let distributedModelVersion = "distributed-star-uncertainty-v1"
    public static let bundleSchemaVersion = "1.0"
    public static let moduleSchemaVersion = "1.0"
    public static let automationAPIVersion = "1.0"
    public static let protocolVersion = "1.0"
    public static let reportSchemaVersion = "1.0"
    public static let databaseSchemaVersion = 5

}
