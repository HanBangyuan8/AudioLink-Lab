import XCTest
import AudioLinkCore
import AudioLinkDSP
@testable import AudioLinkAutomation

final class AutomationTests: XCTestCase {
    func testHeadlessFileAnalysisUsesCoreCorrelation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rate = SampleRate.hz48000
        let reference = try AudioSampleBuffer(samples: [0, 1, 0, 0, 0], format: AudioFormatDescriptor(sampleRate: rate, channelCount: 1, bitDepth: 32, isInterleaved: false))
        let recording = try AudioSampleBuffer(samples: [0, 0, 0, 1, 0, 0, 0], format: AudioFormatDescriptor(sampleRate: rate, channelCount: 1, bitDepth: 32, isInterleaved: false))
        let referenceURL = root.appendingPathComponent("reference.wav"); let recordingURL = root.appendingPathComponent("recording.wav")
        try WAVExporter().write(reference, to: referenceURL); try WAVExporter().write(recording, to: recordingURL)
        let result = try await HeadlessFileAnalyzer().analyze(referenceURL: referenceURL, recordingURL: recordingURL, configuration: .init(method: .direct, normalize: false))
        XCTAssertEqual(result.integerSampleDelay, 2)
        XCTAssertEqual(result.schemaVersion, "1.0")
    }

    func testAuthorizationRejectsPathsOutsideAllowedDirectory() {
        let allowed = FileManager.default.temporaryDirectory.appendingPathComponent("allowed")
        let authorization = AutomationAuthorization(token: "secret", allowedDirectories: [allowed])
        XCTAssertTrue(authorization.isAuthorized("secret"))
        XCTAssertFalse(authorization.isAuthorized("wrong"))
        XCTAssertTrue(authorization.canRead(allowed.appendingPathComponent("file.wav")))
        XCTAssertFalse(authorization.canRead(allowed.deletingLastPathComponent().appendingPathComponent("other.wav")))
    }

    func testAuthorizationRejectsSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let allowed = root.appendingPathComponent("allowed")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideFile = outside.appendingPathComponent("recording.wav")
        try Data("fixture".utf8).write(to: outsideFile)
        let link = allowed.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFile)
        XCTAssertFalse(AutomationAuthorization(token: "secret", allowedDirectories: [allowed]).canRead(link))
    }

    func testRouterHealthRequiresTokenAndRejectsOversizedRequests() async throws {
        let authorization = AutomationAuthorization(token: "secret", maximumRequestBytes: 4)
        let router = LocalAutomationRouter(authorization: authorization)
        let unauthorized = await router.handle(method: "GET", path: "/health", token: "wrong")
        let health = await router.handle(method: "GET", path: "/health", token: "secret")
        let oversized = await router.handle(method: "POST", path: "/v1/jobs/file-analysis", token: "secret", body: Data(repeating: 0, count: 5))
        XCTAssertEqual(unauthorized.statusCode, 401)
        XCTAssertEqual(health.statusCode, 200)
        XCTAssertEqual(oversized.statusCode, 413)
    }

    func testPlanSchemaDefaultsAndUnknownFutureFieldsRemainExternal() throws {
        let data = Data(#"{"schemaVersion":"1.0","tasks":[{"operation":"file-analysis","referenceFile":"r.wav","recordingFile":"t.wav"}],"failurePolicy":"continueOnError","futureField":{"ignored":true}}"#.utf8)
        let plan = try JSONDecoder().decode(AutomationPlan.self, from: data)
        XCTAssertEqual(plan.tasks.count, 1)
        XCTAssertEqual(plan.failurePolicy, .continueOnError)
        XCTAssertEqual(plan.repetitions, 1)
    }

    func testLocalServerIsExplicitAndLoopbackOnly() throws {
        let server = try LocalAutomationServer(port: 0, authorization: AutomationAuthorization(token: "secret"))
        XCTAssertEqual(LocalAutomationServer.bindAddress, "127.0.0.1")
        server.start()
        server.stop()
    }
}
