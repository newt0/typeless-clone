import Foundation
import KoeCore

/// Bridges the hotkey-driven ``AudioCaptureEngine`` into the coordinator's
/// ``AudioCapturing`` seam (E2E wiring PR-B).
///
/// Pairing is keyed, not arrival-ordered: `startUtterance()` returns as soon
/// as its FIFO ticket is reserved, and the spawned pipeline `Task`s reach
/// `record()` in whatever order the scheduler runs them — two overlapping
/// utterances could otherwise swap audio streams (review finding). The key
/// works because press k's stream is the k-th `provide()` (the hotkey callback
/// provides before it enqueues the press, and recording is exclusive) and
/// press k's utterance holds ticket k (the press loop is the coordinator's
/// only caller and awaits each `startUtterance()`, and the serializer hands
/// out contiguous tickets from 0). If a second `startUtterance` caller is ever
/// added, this pairing must be revisited.
@MainActor
final class HotkeyAudioSource: AudioCapturing {
    private var streams: [Int: AudioCaptureEngine.ChunkStream] = [:]
    private var waiters: [Int: CheckedContinuation<AudioCaptureEngine.ChunkStream, Never>] = [:]
    private var nextOrdinal = 0

    /// Called from the hotkey `onStart` with the stream `start()` returned,
    /// before the press is enqueued for `startUtterance()`.
    func provide(_ stream: AudioCaptureEngine.ChunkStream) {
        let ordinal = nextOrdinal
        nextOrdinal += 1
        if let waiter = waiters.removeValue(forKey: ordinal) {
            waiter.resume(returning: stream)
        } else {
            streams[ordinal] = stream
        }
    }

    func record(_ context: UtteranceContext) async throws -> AsyncThrowingStream<Data, any Error> {
        if let stream = streams.removeValue(forKey: context.index) {
            return stream
        }
        return await withCheckedContinuation { waiters[context.index] = $0 }
    }
}
