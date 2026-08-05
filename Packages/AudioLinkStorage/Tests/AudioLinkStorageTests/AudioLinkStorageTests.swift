import AudioLinkCore
import Foundation
import Testing
@testable import AudioLinkStorage

@Test func memoryStoreSavesReplacesAndDeletes() async throws {
    let store: any MeasurementSessionStore = InMemoryMeasurementSessionStore()
    let id = try #require(UUID(uuidString: "D57F7EA1-5C62-49B5-A265-BDEBF8622285"))
    let configuration = MeasurementConfiguration(
        format: AudioFormatDescriptor(
            sampleRate: .hz48000,
            channelCount: 1,
            bitDepth: 32,
            isInterleaved: false
        ),
        signal: .impulse,
        measurementDuration: try DurationSeconds(1),
        repetitions: 1
    )
    let session = MeasurementSession(
        id: id,
        createdAt: Date(timeIntervalSince1970: 100),
        name: "Test",
        configuration: configuration
    )

    try await store.save(session)
    #expect(try await store.session(id: id) == session)
    #expect(try await store.sessions().count == 1)

    try await store.deleteSession(id: id)
    #expect(try await store.session(id: id) == nil)
}
