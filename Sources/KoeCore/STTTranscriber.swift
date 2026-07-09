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
    private let tailTimeout: Duration

    public init(
        client: STTClient,
        vocab: @escaping @Sendable () async -> [STTVocabTerm] = { [] },
        tailTimeout: Duration = KoeConstants.sttStallTimeout
    ) {
        self.client = client
        self.vocab = vocab
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
        _ audio: AsyncStream<Data>,
        _ context: UtteranceContext,
        onRecordingEnded: @escaping @Sendable () async -> Void
    ) async throws -> String {
        let events = try await client.beginUtterance(vocab: await vocab())
        let client = self.client
        let tailTimeout = self.tailTimeout
        return try await withThrowingTaskGroup(of: Step.self) { group in
            group.addTask {
                for await chunk in audio {
                    try await client.send(audioChunk: chunk)
                }
                await onRecordingEnded()
                try await client.endUtterance()
                return .fed
            }
            group.addTask {
                var finals: [String] = []
                for await event in events {
                    switch event {
                    case .partial:
                        break // HUD live text consumes partials, not this seam.
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
                    // socket fails this utterance instead of wedging the FIFO.
                    group.addTask {
                        try await Task.sleep(for: tailTimeout)
                        return .stalled
                    }
                case .transcript(let text):
                    // A cancelled iteration finishes the stream early and would
                    // otherwise surface a truncated transcript as success.
                    try Task.checkCancellation()
                    return text
                case .stalled:
                    Log.error("stt_finals_stalled", category: .stt)
                    throw STTError.timeout
                }
            }
            // Unreachable (the transcript child always returns or throws), but
            // fail closed toward cancellation rather than fabricating text.
            throw CancellationError()
        }
    }
}
