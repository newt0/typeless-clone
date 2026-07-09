import Foundation

/// The streaming attempt failed and the one batch resend failed too (plan
/// M4-T3 double-fault). `audioID` references the persisted WAV for the HUD
/// retry button; `nil` when persisting itself failed (audio is gone — the
/// history row is the audit trail).
public struct UnrecoveredUtterance: Error, Equatable {
    public let audioID: String?
    public init(audioID: String?) { self.audioID = audioID }
}

/// `Transcribing` with the §10.2 failure ladder wrapped around the streaming
/// adapter (plan M4-T3):
///
/// 1. Stream chunks to the primary STT while teeing them into an in-memory
///    tape (the pipeline-side copy of the session audio).
/// 2. If streaming fails — socket error, or no final within the streaming
///    adapter's tail timeout (`sttFinalTimeout` when composed by the app) —
///    wait for the mic stream to finish (the user may still be speaking;
///    capture continues regardless of the dead socket), then resend the whole
///    utterance once to the batch endpoint. Success → the caller only saw
///    added latency.
/// 3. If the batch resend also fails: persist the WAV for the HUD retry
///    button and throw ``UnrecoveredUtterance``.
///
/// A mic-side fault (the audio stream itself throws) is NOT resent: the
/// capture is incomplete, and transcribing a truncated utterance as success
/// is the invariant-1 violation the throwing seam exists to prevent.
public struct ResilientTranscriber: Transcribing {
    private let streaming: any Transcribing
    private let batch: any BatchTranscribing
    private let store: any UntranscribedAudioStoring
    private let vocab: @Sendable () async -> [STTVocabTerm]
    private let format: AudioFormatSpec
    private let batchTimeout: Duration

    public init(
        streaming: any Transcribing,
        batch: any BatchTranscribing,
        store: any UntranscribedAudioStoring,
        vocab: @escaping @Sendable () async -> [STTVocabTerm] = { [] },
        format: AudioFormatSpec = .stt,
        batchTimeout: Duration = KoeConstants.sttBatchResendTimeout
    ) {
        self.streaming = streaming
        self.batch = batch
        self.store = store
        self.vocab = vocab
        self.format = format
        self.batchTimeout = batchTimeout
    }

    public func transcribe(
        _ audio: AsyncThrowingStream<Data, any Error>,
        _ context: UtteranceContext,
        onRecordingEnded: @escaping @Sendable () async -> Void
    ) async throws -> String {
        let tape = AudioTape()
        // The pump outlives the streaming attempt on purpose: when the socket
        // dies mid-utterance the mic keeps capturing, and the resend must
        // cover everything up to the real key-up — not just the chunks the
        // dead socket managed to consume.
        let (teed, pump) = Self.tee(audio, into: tape)

        do {
            return try await streaming.transcribe(teed, context, onRecordingEnded: onRecordingEnded)
        } catch is CancellationError {
            pump.cancel()
            throw CancellationError()
        } catch let error as UnrecoveredUtterance {
            throw error // a nested resilient layer already exhausted the ladder
        } catch {
            // Wait for capture to settle: complete → resend; mic fault → the
            // audio is incomplete, fail loudly with the original error.
            guard await tape.waitUntilSettled() else { throw error }
            let pcm = await tape.pcm
            guard !pcm.isEmpty else { throw error }

            let wav = WAVEncoder.wav(pcm16: pcm, format: format)
            Log.event("stt_batch_resend", category: .stt, code: pcm.count)
            do {
                let batch = self.batch
                let vocab = self.vocab
                let transcript = try await Deadline.run(batchTimeout, onTimeout: { STTError.timeout }) {
                    try await batch.transcribe(wav: wav, vocab: await vocab())
                }
                Log.event("stt_batch_resend_ok", category: .stt)
                return transcript
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.error("stt_batch_resend_failed", category: .stt)
                let audioID = await store.save(wav: wav)
                throw UnrecoveredUtterance(audioID: audioID)
            }
        }
    }

    /// Re-run the batch leg from a previously persisted WAV (HUD retry). The
    /// stored audio is deleted only on success, so retry stays available
    /// across repeated failures within the session.
    public func retryTranscribe(audioID: String) async throws -> String {
        guard let wav = await store.load(id: audioID) else {
            Log.error("stt_retry_audio_missing", category: .stt)
            throw UnrecoveredUtterance(audioID: nil)
        }
        let batch = self.batch
        let vocab = self.vocab
        do {
            let transcript = try await Deadline.run(batchTimeout, onTimeout: { STTError.timeout }) {
                try await batch.transcribe(wav: wav, vocab: await vocab())
            }
            await store.delete(id: audioID)
            Log.event("stt_retry_ok", category: .stt)
            return transcript
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.error("stt_retry_failed", category: .stt)
            throw UnrecoveredUtterance(audioID: audioID)
        }
    }

    // MARK: - Tape plumbing

    private static func tee(
        _ source: AsyncThrowingStream<Data, any Error>,
        into tape: AudioTape
    ) -> (AsyncThrowingStream<Data, any Error>, Task<Void, Never>) {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let pump = Task {
            do {
                for try await chunk in source {
                    await tape.append(chunk)
                    continuation.yield(chunk)
                }
                await tape.markComplete()
                continuation.finish()
            } catch {
                await tape.markFaulted()
                continuation.finish(throwing: error)
            }
        }
        return (stream, pump)
    }
}

extension ResilientTranscriber: RecoveryRetrying {}

/// Accumulates one utterance's PCM and resolves "did capture finish cleanly?"
/// for the resend decision.
private actor AudioTape {
    private(set) var pcm = Data()
    private var settled: Bool? // true = complete, false = mic fault
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func append(_ chunk: Data) { pcm.append(chunk) }
    func markComplete() { settle(true) }
    func markFaulted() { settle(false) }

    /// Suspends until the mic stream ends; `true` when the capture is
    /// complete (safe to resend), `false` on a mic fault.
    func waitUntilSettled() async -> Bool {
        if let settled { return settled }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func settle(_ complete: Bool) {
        settled = complete
        for waiter in waiters { waiter.resume(returning: complete) }
        waiters.removeAll()
    }
}
