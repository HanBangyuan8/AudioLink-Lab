import XCTest
@testable import AudioLinkRealtime

final class PlaybackCompletionGateTests: XCTestCase {
    func testCancellationResolvesContinuationOnlyOnce() async {
        let gate = PlaybackCompletionGate<Int>()
        let value = await withTaskGroup(of: Result<Int, Error>?.self, returning: Result<Int, Error>?.self) { group in
            group.addTask {
                do {
                    let result = try await withCheckedThrowingContinuation { continuation in
                        _ = gate.install(continuation)
                    }
                    return .success(result)
                } catch {
                    return .failure(error)
                }
            }
            try? await Task.sleep(for: .milliseconds(1))
            gate.cancel()
            gate.finish(returning: 99)
            return await group.next()!
        }

        guard case let .failure(error)? = value else {
            return XCTFail("Expected cancellation to win over completion")
        }
        XCTAssertTrue(error is CancellationError)
    }

    func testCompletionWinsWhenItArrivesFirst() async throws {
        let gate = PlaybackCompletionGate<Int>()
        let task = Task {
            try await withCheckedThrowingContinuation { continuation in
                _ = gate.install(continuation)
            }
        }
        try? await Task.sleep(for: .milliseconds(1))
        gate.finish(returning: 7)
        let value = try await task.value
        XCTAssertEqual(value, 7)
        gate.cancel()
    }
}
