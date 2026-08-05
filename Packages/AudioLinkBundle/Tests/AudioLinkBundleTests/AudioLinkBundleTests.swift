import XCTest
@testable import AudioLinkBundle

final class AudioLinkBundleTests: XCTestCase {
    func testDirectoryBundleRoundTripsAndChecksums() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("result.json")
        let destination = root.appendingPathComponent("sample.audiolinkbundle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"delaySamples": 42}"#.utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try AudioLinkBundleWriter().write(
            manifest: BundleManifest(creatorAppVersion: "test", algorithmVersion: "test-v1", protocolVersion: "1", measurementType: "file-delay", privacyLevel: .standard, anonymizationLevel: .standard),
            files: [BundleInputFile(sourceURL: source, relativePath: "results/result.json", contentType: "application/json")],
            to: destination
        )
        XCTAssertEqual(manifest.content.count, 1)
        let validation = try AudioLinkBundleValidator().validate(destination)
        XCTAssertTrue(validation.isValid)
        XCTAssertEqual(try AudioLinkBundleValidator().readManifest(destination).bundleID, manifest.bundleID)
    }

    func testChecksumMismatchAndTraversalAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("result.json")
        let destination = root.appendingPathComponent("sample.audiolinkbundle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try AudioLinkBundleWriter().write(
            manifest: BundleManifest(creatorAppVersion: "test", algorithmVersion: "test", protocolVersion: "1", measurementType: "test", privacyLevel: .strict, anonymizationLevel: .strict),
            files: [BundleInputFile(sourceURL: source, relativePath: "../escape")], to: destination
        )) { XCTAssertEqual($0 as? BundleError, .invalidRelativePath("../escape")) }
        _ = try AudioLinkBundleWriter().write(
            manifest: BundleManifest(creatorAppVersion: "test", algorithmVersion: "test", protocolVersion: "1", measurementType: "test", privacyLevel: .minimal, anonymizationLevel: .minimal),
            files: [BundleInputFile(sourceURL: source, relativePath: "result.txt")], to: destination
        )
        try Data("world".utf8).write(to: destination.appendingPathComponent("result.txt"))
        let validation = try AudioLinkBundleValidator().validate(destination)
        XCTAssertFalse(validation.isValid)
        XCTAssertTrue(validation.errors.contains { $0.contains("checksum") })
    }

    func testUnsupportedSchemaAndDuplicateEntriesAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("data")
        try Data("data".utf8).write(to: source)
        let destination = root.appendingPathComponent("bundle")
        let manifest = try AudioLinkBundleWriter().write(
            manifest: BundleManifest(creatorAppVersion: "test", algorithmVersion: "test", protocolVersion: "1", measurementType: "test", privacyLevel: .minimal, anonymizationLevel: .minimal),
            files: [BundleInputFile(sourceURL: source, relativePath: "data")], to: destination
        )
        let duplicate = BundleManifest(bundleID: manifest.bundleID, creatorAppVersion: "test", algorithmVersion: "test", protocolVersion: "1", measurementType: "test", privacyLevel: .minimal, anonymizationLevel: .minimal, content: manifest.content + manifest.content)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(duplicate).write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
        let validation = try AudioLinkBundleValidator().validate(destination)
        XCTAssertFalse(validation.isValid)
        XCTAssertTrue(validation.errors.contains { $0.contains("duplicate") })
    }

    func testAnonymizationLevelsAndBundleLocalPseudonyms() {
        guard let bundleID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") else {
            XCTFail("Fixture UUID should be valid")
            return
        }
        let metadata = ["deviceUID": "real-device", "absolutePath": "/Users/example/take.wav", "notes": "review /Users/example later"]
        let standard = BundleAnonymizer.anonymize(metadata: metadata, level: .standard, bundleID: bundleID)
        let second = BundleAnonymizer.anonymize(metadata: metadata, level: .standard, bundleID: bundleID)
        XCTAssertEqual(standard.metadata["deviceUID"], second.metadata["deviceUID"])
        XCTAssertNil(standard.metadata["absolutePath"])
        XCTAssertTrue(standard.audit.warnings.contains { $0.contains("Free text") })
        let strict = BundleAnonymizer.anonymize(metadata: metadata, level: .strict, bundleID: bundleID)
        XCTAssertNil(strict.metadata["notes"])
        XCTAssertNotEqual(standard.metadata["deviceUID"], BundleAnonymizer.pseudonym(for: "real-device", bundleID: UUID()))
    }
}
