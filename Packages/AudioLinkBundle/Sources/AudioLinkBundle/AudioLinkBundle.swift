import CryptoKit
import Foundation

public enum BundlePrivacyLevel: String, Codable, CaseIterable, Sendable {
    case minimal
    case standard
    case strict
}

public enum BundleValidationStatus: String, Codable, CaseIterable, Sendable {
    case notValidated
    case validated
    case failed
}

public struct BundleFileEntry: Codable, Equatable, Sendable {
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String
    public let contentType: String
    public let isOptional: Bool

    public init(relativePath: String, byteCount: Int64, sha256: String,
                contentType: String = "application/octet-stream", isOptional: Bool = false) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.contentType = contentType
        self.isOptional = isOptional
    }
}

public struct BundleManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "1.0"

    public let schemaVersion: String
    public let bundleID: UUID
    public let createdAt: Date
    public let creatorAppVersion: String
    public let algorithmVersion: String
    public let protocolVersion: String
    public let measurementType: String
    public let privacyLevel: BundlePrivacyLevel
    public let anonymizationLevel: BundlePrivacyLevel
    public let requiredCapabilities: [String]
    public let content: [BundleFileEntry]
    public let validationStatus: BundleValidationStatus
    public let notes: String?
    public let signaturePlaceholder: String?

    public init(schemaVersion: String = BundleManifest.currentSchemaVersion,
                bundleID: UUID = UUID(), createdAt: Date = Date(),
                creatorAppVersion: String, algorithmVersion: String,
                protocolVersion: String, measurementType: String,
                privacyLevel: BundlePrivacyLevel,
                anonymizationLevel: BundlePrivacyLevel,
                requiredCapabilities: [String] = [], content: [BundleFileEntry] = [],
                validationStatus: BundleValidationStatus = .notValidated,
                notes: String? = nil, signaturePlaceholder: String? = nil) {
        self.schemaVersion = schemaVersion
        self.bundleID = bundleID
        self.createdAt = createdAt
        self.creatorAppVersion = creatorAppVersion
        self.algorithmVersion = algorithmVersion
        self.protocolVersion = protocolVersion
        self.measurementType = measurementType
        self.privacyLevel = privacyLevel
        self.anonymizationLevel = anonymizationLevel
        self.requiredCapabilities = requiredCapabilities
        self.content = content
        self.validationStatus = validationStatus
        self.notes = notes
        self.signaturePlaceholder = signaturePlaceholder
    }
}

public struct BundleInputFile: Sendable {
    public let sourceURL: URL
    public let relativePath: String
    public let contentType: String
    public let isOptional: Bool

    public init(sourceURL: URL, relativePath: String, contentType: String = "application/octet-stream", isOptional: Bool = false) {
        self.sourceURL = sourceURL
        self.relativePath = relativePath
        self.contentType = contentType
        self.isOptional = isOptional
    }
}

public struct BundleWriteOptions: Codable, Equatable, Sendable {
    public let privacyLevel: BundlePrivacyLevel
    public let includeAudio: Bool
    public let overwrite: Bool
    public let maximumBundleBytes: Int64

    public init(privacyLevel: BundlePrivacyLevel = .minimal, includeAudio: Bool = false,
                overwrite: Bool = false, maximumBundleBytes: Int64 = 2_000_000_000) {
        self.privacyLevel = privacyLevel
        self.includeAudio = includeAudio
        self.overwrite = overwrite
        self.maximumBundleBytes = maximumBundleBytes
    }
}

public struct BundleIntegrityResult: Codable, Equatable, Sendable {
    public let isValid: Bool
    public let bundleID: UUID?
    public let checkedFileCount: Int
    public let totalBytes: Int64
    public let errors: [String]
    public let warnings: [String]

    public init(isValid: Bool, bundleID: UUID? = nil, checkedFileCount: Int,
                totalBytes: Int64, errors: [String] = [], warnings: [String] = []) {
        self.isValid = isValid
        self.bundleID = bundleID
        self.checkedFileCount = checkedFileCount
        self.totalBytes = totalBytes
        self.errors = errors
        self.warnings = warnings
    }
}

public struct BundlePrivacyAudit: Codable, Equatable, Sendable {
    public let level: BundlePrivacyLevel
    public let removedFields: [String]
    public let warnings: [String]
    public let pseudonymizedIdentifiers: [String: String]

    public init(level: BundlePrivacyLevel, removedFields: [String] = [], warnings: [String] = [],
                pseudonymizedIdentifiers: [String: String] = [:]) {
        self.level = level
        self.removedFields = removedFields
        self.warnings = warnings
        self.pseudonymizedIdentifiers = pseudonymizedIdentifiers
    }
}

public struct BundleAnonymizationResult: Codable, Equatable, Sendable {
    public let metadata: [String: String]
    public let audit: BundlePrivacyAudit
    public init(metadata: [String: String], audit: BundlePrivacyAudit) { self.metadata = metadata; self.audit = audit }
}

/// Conservative key-based anonymization for bundle metadata. It intentionally
/// does not claim perfect detection of personal information in free text.
public enum BundleAnonymizer {
    public static func anonymize(metadata: [String: String], level: BundlePrivacyLevel, bundleID: UUID) -> BundleAnonymizationResult {
        var output: [String: String] = [:]
        var removed: [String] = []
        var pseudonyms: [String: String] = [:]
        let sensitive = ["username", "user", "home", "path", "bookmark", "serial", "token", "networkAddress", "ipAddress", "license"]
        for (key, value) in metadata {
            let normalized = key.lowercased()
            if sensitive.contains(where: { normalized.contains($0.lowercased()) }) {
                removed.append(key); continue
            }
            if level == .strict {
                if normalized.contains("note") || normalized.contains("name") || normalized.contains("text") { removed.append(key); continue }
            }
            if level != .minimal && (normalized.contains("uid") || normalized.contains("identifier")) {
                let pseudonym = pseudonym(for: value, bundleID: bundleID)
                output[key] = pseudonym; pseudonyms[key] = pseudonym
            } else {
                output[key] = sanitizeFreeText(value, level: level)
            }
        }
        let warnings = metadata.keys.contains { $0.lowercased().contains("note") } && level != .strict
            ? ["Free text was retained; review it manually for personal information."] : []
        return BundleAnonymizationResult(metadata: output, audit: BundlePrivacyAudit(level: level, removedFields: removed.sorted(), warnings: warnings, pseudonymizedIdentifiers: pseudonyms))
    }

    public static func pseudonym(for identifier: String, bundleID: UUID) -> String {
        let digest = SHA256.hash(data: Data((bundleID.uuidString + ":" + identifier).utf8))
        return "id-" + digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizeFreeText(_ value: String, level: BundlePrivacyLevel) -> String {
        guard level != .minimal else { return value }
        var sanitized = value.replacingOccurrences(of: #"/(Users|private/var)/[^\s,;]+"#, with: "[path]", options: .regularExpression)
        sanitized = sanitized.replacingOccurrences(of: #"file://[^\s,;]+"#, with: "[path]", options: .regularExpression)
        return sanitized
    }
}

public enum BundleError: Error, Equatable, Sendable, LocalizedError {
    case destinationExists(URL)
    case invalidRelativePath(String)
    case sourceMissing(URL)
    case sourceIsDirectory(URL)
    case manifestMissing
    case unsupportedSchema(String)
    case malformedManifest(String)
    case checksumMismatch(String)
    case duplicateEntry(String)
    case sizeLimitExceeded(Int64)
    case pathTraversal(String)
    case requiredFileMissing(String)
    case filesystem(String)

    public var errorDescription: String? {
        switch self {
        case .destinationExists: "The bundle destination already exists; pass overwrite explicitly."
        case .invalidRelativePath: "The bundle contains an unsafe relative path."
        case .sourceMissing: "A bundle source file could not be found."
        case .sourceIsDirectory: "A bundle source must be a regular file."
        case .manifestMissing: "The bundle manifest is missing."
        case .unsupportedSchema: "This bundle schema version is not supported."
        case .malformedManifest: "The bundle manifest is malformed."
        case .checksumMismatch: "A bundle file checksum does not match its manifest."
        case .duplicateEntry: "The bundle manifest contains a duplicate file entry."
        case .sizeLimitExceeded: "The bundle exceeds the configured expansion limit."
        case .pathTraversal: "The bundle attempted to escape its root directory."
        case .requiredFileMissing: "A required bundle file is missing."
        case .filesystem: "The bundle could not be read or written."
        }
    }
}

public struct AudioLinkBundleWriter: Sendable {
    public init() {}

    public func write(manifest: BundleManifest, files: [BundleInputFile], to destination: URL,
                      options: BundleWriteOptions = .init()) throws -> BundleManifest {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            guard options.overwrite else { throw BundleError.destinationExists(destination) }
            try fileManager.removeItem(at: destination)
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".audiolinkbundle-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
            var entries: [BundleFileEntry] = []
            var totalBytes: Int64 = 0
            for input in files {
                try Self.validateRelativePath(input.relativePath)
                guard fileManager.fileExists(atPath: input.sourceURL.path) else { throw BundleError.sourceMissing(input.sourceURL) }
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: input.sourceURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    throw BundleError.sourceIsDirectory(input.sourceURL)
                }
                let attributes = try fileManager.attributesOfItem(atPath: input.sourceURL.path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                let (newTotal, overflowed) = totalBytes.addingReportingOverflow(size)
                guard !overflowed else { throw BundleError.sizeLimitExceeded(Int64.max) }
                totalBytes = newTotal
                guard totalBytes <= options.maximumBundleBytes else { throw BundleError.sizeLimitExceeded(totalBytes) }
                let target = temporary.appendingPathComponent(input.relativePath)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: input.sourceURL, to: target)
                entries.append(BundleFileEntry(relativePath: input.relativePath, byteCount: size,
                                               sha256: try Self.sha256(url: target), contentType: input.contentType,
                                               isOptional: input.isOptional))
            }
            let finalManifest = BundleManifest(schemaVersion: manifest.schemaVersion, bundleID: manifest.bundleID,
                                               createdAt: manifest.createdAt, creatorAppVersion: manifest.creatorAppVersion,
                                               algorithmVersion: manifest.algorithmVersion, protocolVersion: manifest.protocolVersion,
                                               measurementType: manifest.measurementType, privacyLevel: manifest.privacyLevel,
                                               anonymizationLevel: manifest.anonymizationLevel, requiredCapabilities: manifest.requiredCapabilities,
                                               content: entries.sorted { $0.relativePath < $1.relativePath },
                                               validationStatus: .notValidated, notes: manifest.notes,
                                               signaturePlaceholder: manifest.signaturePlaceholder)
            let data = try Self.encoder.encode(finalManifest)
            try data.write(to: temporary.appendingPathComponent("manifest.json"), options: .atomic)
            try fileManager.moveItem(at: temporary, to: destination)
            return finalManifest
        } catch {
            try? fileManager.removeItem(at: temporary)
            if let bundleError = error as? BundleError { throw bundleError }
            throw BundleError.filesystem(String(describing: error))
        }
    }

    fileprivate static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    fileprivate static func sha256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { throw BundleError.invalidRelativePath(path) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw BundleError.invalidRelativePath(path) }
        guard path != "manifest.json" else { throw BundleError.invalidRelativePath(path) }
    }
}

public struct AudioLinkBundleValidator: Sendable {
    public let maximumExpandedBytes: Int64
    private let maximumManifestBytes = 4 * 1024 * 1024

    public init(maximumExpandedBytes: Int64 = 2_000_000_000) {
        self.maximumExpandedBytes = maximumExpandedBytes
    }

    public func validate(_ directory: URL) throws -> BundleIntegrityResult {
        var errors: [String] = []
        var warnings: [String] = []
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw BundleError.manifestMissing }
        let manifest: BundleManifest
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard size >= 0, size <= Int64(maximumManifestBytes) else { throw BundleError.sizeLimitExceeded(size) }
            manifest = try decoder.decode(BundleManifest.self, from: Data(contentsOf: manifestURL))
        } catch { throw BundleError.malformedManifest(String(describing: error)) }
        guard manifest.schemaVersion == BundleManifest.currentSchemaVersion else { throw BundleError.unsupportedSchema(manifest.schemaVersion) }
        var seen = Set<String>()
        var seenCaseFolded = Set<String>()
        var total: Int64 = 0
        for entry in manifest.content {
            do { try AudioLinkBundleWriter.validateRelativePath(entry.relativePath) }
            catch { errors.append(String(describing: error)); continue }
            guard seen.insert(entry.relativePath).inserted,
                  seenCaseFolded.insert(entry.relativePath.lowercased(with: Locale(identifier: "en_US_POSIX"))).inserted else {
                errors.append(BundleError.duplicateEntry(entry.relativePath).localizedDescription); continue
            }
            let fileURL = directory.appendingPathComponent(entry.relativePath).standardizedFileURL
            let resolvedFileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedFileURL.path.hasPrefix(resolvedDirectory.path + "/") else { errors.append(BundleError.pathTraversal(entry.relativePath).localizedDescription); continue }
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                if entry.isOptional { warnings.append("Optional file missing: \(entry.relativePath)") }
                else { errors.append(BundleError.requiredFileMissing(entry.relativePath).localizedDescription) }
                continue
            }
            if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                errors.append("Symbolic links are not allowed: \(entry.relativePath)")
                continue
            }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard byteCount == entry.byteCount else { errors.append("Size mismatch: \(entry.relativePath)"); continue }
                let (newTotal, overflowed) = total.addingReportingOverflow(byteCount)
                guard !overflowed else { throw BundleError.sizeLimitExceeded(Int64.max) }
                total = newTotal
                guard total <= maximumExpandedBytes else { throw BundleError.sizeLimitExceeded(total) }
                guard try AudioLinkBundleWriter.sha256(url: fileURL) == entry.sha256 else { errors.append(BundleError.checksumMismatch(entry.relativePath).localizedDescription); continue }
            } catch let error as BundleError { errors.append(error.localizedDescription) }
            catch { errors.append("Unable to inspect \(entry.relativePath): \(error.localizedDescription)") }
        }
        if manifest.content.isEmpty { warnings.append("Bundle contains no payload files.") }
        return BundleIntegrityResult(isValid: errors.isEmpty, bundleID: manifest.bundleID,
                                     checkedFileCount: seen.count, totalBytes: total,
                                     errors: errors, warnings: warnings)
    }

    public func readManifest(_ directory: URL) throws -> BundleManifest {
        let url = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw BundleError.manifestMissing }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size >= 0, size <= Int64(maximumManifestBytes) else { throw BundleError.sizeLimitExceeded(size) }
        let manifest = try decoder.decode(BundleManifest.self, from: Data(contentsOf: url))
        guard manifest.schemaVersion == BundleManifest.currentSchemaVersion else { throw BundleError.unsupportedSchema(manifest.schemaVersion) }
        return manifest
    }
}
