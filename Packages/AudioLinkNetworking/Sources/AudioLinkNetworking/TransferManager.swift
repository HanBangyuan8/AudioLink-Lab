import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct FileTransferLimits: Codable, Equatable, Sendable {
    public let maxFileBytes: Int64
    public let maxChunkBytes: Int
    public let maxChunkCount: Int

    public init(_ limits: ProtocolLimits = .default) {
        self.maxFileBytes = limits.maxFileBytes
        self.maxChunkBytes = limits.maxChunkBytes
        self.maxChunkCount = limits.maxChunkCount
    }
}

public struct FileTransferProgress: Equatable, Sendable {
    public let transferID: UUID
    public let bytesTransferred: Int64
    public let totalBytes: Int64
    public var fraction: Double { totalBytes > 0 ? Double(bytesTransferred) / Double(totalBytes) : 1 }
    public init(transferID: UUID, bytesTransferred: Int64, totalBytes: Int64) {
        self.transferID = transferID; self.bytesTransferred = bytesTransferred; self.totalBytes = totalBytes
    }
}

public struct FileTransferResult: Equatable, Sendable {
    public let transferID: UUID
    public let destinationURL: URL
    public let bytesTransferred: Int64
    public let sha256: String
    public init(transferID: UUID, destinationURL: URL, bytesTransferred: Int64, sha256: String) {
        self.transferID = transferID; self.destinationURL = destinationURL; self.bytesTransferred = bytesTransferred; self.sha256 = sha256
    }
}

public actor TransferManager {
    private let limits: FileTransferLimits

    public init(limits: FileTransferLimits = .init()) { self.limits = limits }

    public func sendFile(
        at sourceURL: URL,
        over connection: PeerConnection,
        sessionID: UUID,
        sessionToken: Data? = nil,
        transferID: UUID = UUID(),
        progress: (@Sendable (FileTransferProgress) async -> Void)? = nil
    ) async throws -> FileTransferResult {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard let size = attributes[.size] as? NSNumber else { throw ProtocolError.transferInterrupted }
        let fileSize = size.int64Value
        guard fileSize >= 0, fileSize <= limits.maxFileBytes else { throw ProtocolError.fileTooLarge(limit: limits.maxFileBytes) }
        let safeName = sourceURL.lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != ".." else { throw ProtocolError.invalidFileName }
        let checksum = try Self.sha256(fileURL: sourceURL)
        let start = FileTransferStartPayload(
            transferID: transferID,
            fileName: safeName,
            fileSizeBytes: fileSize,
            sha256: checksum,
            chunkSizeBytes: min(limits.maxChunkBytes, 64 * 1024)
        )
        try await sendMessage(start, kind: .fileTransferStart, over: connection, sessionID: sessionID, token: sessionToken, sequence: 1)

        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }
        var index = 0
        var sent: Int64 = 0
        while sent < fileSize || (fileSize == 0 && index == 0) {
            try Task.checkCancellation()
            guard index < limits.maxChunkCount else { throw ProtocolError.fileTooLarge(limit: limits.maxFileBytes) }
            let data = try handle.read(upToCount: start.chunkSizeBytes) ?? Data()
            if data.isEmpty && fileSize > sent { throw ProtocolError.transferInterrupted }
            let chunk = FileChunkPayload(transferID: transferID, index: index, bytes: data)
            try await sendMessage(chunk, kind: .fileChunk, over: connection, sessionID: sessionID, token: sessionToken, sequence: UInt64(index + 2))
            sent += Int64(data.count)
            index += 1
            if let progress { await progress(FileTransferProgress(transferID: transferID, bytesTransferred: sent, totalBytes: fileSize)) }
            if fileSize == 0 { break }
        }
        try await sendMessage(FileTransferCompletePayload(transferID: transferID), kind: .fileTransferComplete, over: connection, sessionID: sessionID, token: sessionToken, sequence: UInt64(index + 2))
        return FileTransferResult(transferID: transferID, destinationURL: sourceURL, bytesTransferred: sent, sha256: checksum)
    }

    public func receiveFile(
        from connection: PeerConnection,
        destinationDirectory: URL,
        sessionID: UUID,
        sessionToken: Data? = nil,
        progress: (@Sendable (FileTransferProgress) async -> Void)? = nil
    ) async throws -> FileTransferResult {
        var start: FileTransferStartPayload?
        var handle: FileHandle?
        var temporaryURL: URL?
        var bytesReceived: Int64 = 0
        var expectedIndex = 0
        let replayGuard = ReplayGuard()
        do {
            while let message = try await connection.receive() {
                try await replayGuard.accept(message)
                guard message.sessionID == sessionID else { throw ProtocolError.sessionMismatch }
                if let sessionToken { guard message.sessionToken == sessionToken else { throw ProtocolError.notPaired } }
                switch message.kind {
                case .fileTransferStart:
                    guard start == nil else { throw ProtocolError.invalidState("A second transfer started before the first completed.") }
                    let payload = try message.decodePayload(FileTransferStartPayload.self)
                    guard payload.fileSizeBytes >= 0, payload.fileSizeBytes <= limits.maxFileBytes,
                          payload.chunkSizeBytes > 0, payload.chunkSizeBytes <= limits.maxChunkBytes else {
                        throw ProtocolError.fileTooLarge(limit: limits.maxFileBytes)
                    }
                    let name = URL(fileURLWithPath: payload.fileName).lastPathComponent
                    guard name == payload.fileName, !name.isEmpty, name != ".", name != "..",
                          !name.contains("/"), !name.contains("\\"),
                          !name.unicodeScalars.contains(where: { $0.value < 0x20 }) else { throw ProtocolError.invalidFileName }
                    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                    let resolvedDirectory = destinationDirectory.standardizedFileURL.resolvingSymlinksInPath()
                    guard resolvedDirectory.path == destinationDirectory.standardizedFileURL.path else {
                        throw ProtocolError.invalidFileName
                    }
                    if let capacity = try FileManager.default.attributesOfFileSystem(forPath: destinationDirectory.path)[.systemFreeSize] as? NSNumber,
                       capacity.int64Value < payload.fileSizeBytes {
                        throw ProtocolError.transferInterrupted
                    }
                    let temporary = destinationDirectory.appendingPathComponent(".\(UUID().uuidString).part")
                    FileManager.default.createFile(atPath: temporary.path, contents: nil)
                    handle = try FileHandle(forWritingTo: temporary)
                    temporaryURL = temporary
                    start = payload
                case .fileChunk:
                    guard let start, let handle else { throw ProtocolError.invalidState("Received a file chunk before transfer start.") }
                    let payload = try message.decodePayload(FileChunkPayload.self)
                    guard payload.transferID == start.transferID, payload.index == expectedIndex,
                          payload.bytes.count <= start.chunkSizeBytes,
                          bytesReceived + Int64(payload.bytes.count) <= start.fileSizeBytes else {
                        throw ProtocolError.transferInterrupted
                    }
                    try handle.write(contentsOf: payload.bytes)
                    bytesReceived += Int64(payload.bytes.count)
                    expectedIndex += 1
                    if let progress { await progress(FileTransferProgress(transferID: start.transferID, bytesTransferred: bytesReceived, totalBytes: start.fileSizeBytes)) }
                case .fileTransferComplete:
                    guard let start, let temporaryURL, let handle else { throw ProtocolError.transferInterrupted }
                    let payload = try message.decodePayload(FileTransferCompletePayload.self)
                    guard payload.transferID == start.transferID, bytesReceived == start.fileSizeBytes else { throw ProtocolError.transferInterrupted }
                    try handle.close()
                    let checksum = try Self.sha256(fileURL: temporaryURL)
                    guard checksum.caseInsensitiveCompare(start.sha256) == .orderedSame else { throw ProtocolError.checksumMismatch(expected: start.sha256, actual: checksum) }
                    let destination = destinationDirectory.appendingPathComponent(start.fileName)
                    guard !FileManager.default.fileExists(atPath: destination.path) else {
                        throw ProtocolError.invalidState("The destination file already exists; no existing user data was replaced.")
                    }
                    try FileManager.default.moveItem(at: temporaryURL, to: destination)
                    return FileTransferResult(transferID: start.transferID, destinationURL: destination, bytesTransferred: bytesReceived, sha256: checksum)
                default:
                    continue
                }
            }
            throw ProtocolError.transferInterrupted
        } catch is CancellationError {
            if let handle { try? handle.close() }
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            throw ProtocolError.cancellation
        } catch {
            if let handle { try? handle.close() }
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            throw error
        }
    }

    private func sendMessage<P: Encodable>(_ payload: P, kind: ProtocolMessageKind, over connection: PeerConnection, sessionID: UUID, token: Data?, sequence: UInt64) async throws {
        let message = try ProtocolMessage(sessionID: sessionID, sequence: sequence, kind: kind, payload: payload, sessionToken: token)
        try await connection.send(message)
    }

    private static func sha256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        #if canImport(CryptoKit)
        var digest = SHA256()
        while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        var state: UInt64 = 0xcbf29ce484222325
        while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
            for byte in data { state = (state ^ UInt64(byte)) &* 0x100000001b3 }
        }
        return String(format: "%016llx", state)
        #endif
    }
}
