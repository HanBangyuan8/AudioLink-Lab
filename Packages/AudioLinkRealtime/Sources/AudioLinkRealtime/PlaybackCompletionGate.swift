import Foundation

/// Owns the single continuation used by an audio-player completion callback.
///
/// AVAudioPlayerNode does not guarantee that stopping a node will invoke a
/// scheduled buffer's completion callback.  The gate therefore makes normal
/// completion and cancellation mutually exclusive and lets the cancellation
/// path finish the waiting task even when the hardware callback never arrives.
final class PlaybackCompletionGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var isFinished = false

    @discardableResult
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func finish(returning value: Value) {
        resolve { $0.resume(returning: value) }
    }

    func cancel() {
        resolve { $0.resume(throwing: CancellationError()) }
    }

    private func resolve(_ resume: (CheckedContinuation<Value, Error>) -> Void) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let continuation {
            resume(continuation)
        }
    }
}
