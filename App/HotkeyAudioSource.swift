import Foundation
import KoeCore

/// Bridges the hotkey-driven ``AudioCaptureEngine`` into the coordinator's
/// ``AudioCapturing`` seam (E2E wiring PR-B).
///
/// The engine's stream is created by `start()` in the hotkey callback (so the
/// press→recording budget isn't paid inside the pipeline), then handed over
/// here; the coordinator's `record()` picks it up. Both sides run on the main
/// actor, so the handoff is a plain FIFO with no reordering window — and
/// recording is exclusive anyway (`start()` refuses while already recording),
/// so at most one stream is ever in flight per utterance.
@MainActor
final class HotkeyAudioSource: AudioCapturing {
    private var pending: [AudioCaptureEngine.ChunkStream] = []
    private var waiters: [CheckedContinuation<AudioCaptureEngine.ChunkStream, Never>] = []

    /// Called from the hotkey `onStart` with the stream `start()` returned.
    func provide(_ stream: AudioCaptureEngine.ChunkStream) {
        if waiters.isEmpty {
            pending.append(stream)
        } else {
            waiters.removeFirst().resume(returning: stream)
        }
    }

    func record(_ context: UtteranceContext) async throws -> AsyncThrowingStream<Data, any Error> {
        if !pending.isEmpty {
            return Self.bridge(pending.removeFirst())
        }
        let stream = await withCheckedContinuation { waiters.append($0) }
        return Self.bridge(stream)
    }

    /// Adapt the engine's non-throwing stream to the seam's throwing shape.
    /// The engine cannot yet signal a mid-capture fault (it ends the stream
    /// the same way as a normal stop; splitting that is the M9 `onCapReached`
    /// callback work), so today this bridge never throws — but the seam
    /// contract is ready for it.
    private static func bridge(_ stream: AudioCaptureEngine.ChunkStream) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let pump = Task {
                for await chunk in stream { continuation.yield(chunk) }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }
}
