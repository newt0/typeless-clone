import Foundation

/// Adapts the streaming ``STTClient`` behind the coordinator's ``Transcribing``
/// seam (see the M4 note in SessionSeams): forwards live audio chunks as they
/// are captured, signals end-of-recording the moment the mic stream finishes,
/// and concatenates the settling finals into the utterance transcript.
///
/// The finals tail (end-of-speech → provider end-of-transcript) is bounded by
/// `tailTimeout`: a dead socket that accepted the audio but never confirms
/// would otherwise hang this utterance forever — and, because every FIFO
/// ticket must eventually complete, wedge insertion for every utterance behind
/// it. The recording leg is deliberately unbounded: its length is the user's
/// to choose, capped upstream by `KoeConstants.maxSessionRecording`.
public struct STTTranscriber: Transcribing {
    private let client: STTClient
    /// Personal-dictionary vocabulary, fetched fresh per utterance (cheap; the
    /// client takes it per `beginUtterance`), so dictionary edits apply to STT
    /// without an app restart.
    private let vocab: @Sendable () async -> [STTVocabTerm]
    /// Live-partial side channel for the HUD (M9). Called per `.partial` event
    /// with the utterance it belongs to; display-only, never persisted/logged.
    private let onPartial: @Sendable (String, UtteranceContext) -> Void
    private let tailTimeout: Duration

    public init(
        client: STTClient,
        vocab: @escaping @Sendable () async -> [STTVocabTerm] = { [] },
        onPartial: @escaping @Sendable (String, UtteranceContext) -> Void = { _, _ in },
        tailTimeout: Duration = KoeConstants.sttStallTimeout
    ) {
        self.client = client
        self.vocab = vocab
        self.onPartial = onPartial
        self.tailTimeout = tailTimeout
    }

    private enum Step: Sendable {
        /// All audio sent and `endUtterance` flushed; finals may still settle.
        case fed
        /// The event stream finished; the utterance transcript is complete.
        case transcript(String)
        /// The finals tail exceeded `tailTimeout` after end-of-speech.
        case stalled
    }

    public func transcribe(
        _ audio: AsyncThrowingStream<Data, any Error>,
        _ context: UtteranceContext,
        onRecordingEnded: @escaping @Sendable () async -> Void
    ) async throws -> String {
        let events = try await client.beginUtterance(vocab: await vocab())
        let client = self.client
        let tailTimeout = self.tailTimeout
        let onPartial = self.onPartial
        // The seam contract is exactly-once on EVERY exit: the provider can
        // finalize before the mic stream ends, and a failed send must not skip
        // the callback — either way the session has to leave `recording`.
        let recordingEnded = Once(onRecordingEnded)
        do {
            return try await withThrowingTaskGroup(of: Step.self) { group in
                group.addTask {
                    for try await chunk in audio {
                        try await client.send(audioChunk: chunk)
                    }
                    await recordingEnded.fire()
                    try await client.endUtterance()
                    return .fed
                }
                group.addTask {
                    var finals: [String] = []
                    for await event in events {
                        switch event {
                        case .partial(let text):
                            onPartial(text, context) // HUD live line (M9)
                        case .final(let text):
                            finals.append(text)
                        case .error(let error):
                            throw error
                        }
                    }
                    return .transcript(finals.joined())
                }
                defer { group.cancelAll() }
                while let step = try await group.next() {
                    switch step {
                    case .fed:
                        // End of speech: bound the remaining finals so a dead
                        // socket fails this utterance instead of wedging the
                        // FIFO. Hand-rolled rather than `Deadline.run` because
                        // this deadline starts mid-race (at `.fed`), not at the
                        // operation's start, which is the shape Deadline bounds.
                        group.addTask {
                            try await Task.sleep(for: tailTimeout)
                            return .stalled
                        }
                    case .transcript(let text):
                        // A cancelled iteration finishes the stream early and
                        // would otherwise surface a truncated transcript as
                        // success.
                        try Task.checkCancellation()
                        // The provider finalized before the mic stream ended
                        // (early server close): the utterance is complete, so
                        // recording is over even though key-up hasn't happened.
                        await recordingEnded.fire()
                        return text
                    case .stalled:
                        Log.error("stt_finals_stalled", category: .stt)
                        throw STTError.timeout
                    }
                }
                // Unreachable (the transcript child always returns or throws),
                // but fail closed toward cancellation, not fabricated text.
                throw CancellationError()
            }
        } catch {
            await recordingEnded.fire()
            throw error
        }
    }
}

/// Runs its body on the first `fire()` only — the exactly-once guarantee for
/// `onRecordingEnded` across racing exit paths.
private actor Once {
    private let body: @Sendable () async -> Void
    private var fired = false
    init(_ body: @escaping @Sendable () async -> Void) { self.body = body }
    func fire() async {
        guard !fired else { return }
        fired = true
        await body()
    }
}
