import Foundation

/// The state machine for one dictation lifecycle (Design §7.2; plan M1-T1).
///
/// A single `actor` serializes all transitions, so consecutive utterances can
/// pipeline (recording of N+1 while N formats) without races. Each event method
/// applies exactly one transition, stamps the relevant ``DictationMetrics``
/// field, and yields the new state on ``states`` for the HUD/status item to
/// render (UI is a pure projection of this state — no logic in the UI).
///
/// Payloads (transcript, formatted text, result, error) are stored here; the
/// enum in ``DictationState`` models only the state kind.
public actor DictationSession {
    // MARK: Observable state

    public private(set) var state: DictationState = .idle
    /// State changes, in order, starting with the current state. The HUD and
    /// status item consume this; it never carries body text.
    public nonisolated let states: AsyncStream<DictationState>
    private let stateContinuation: AsyncStream<DictationState>.Continuation

    // MARK: Data captured through the lifecycle

    public private(set) var metrics = DictationMetrics()
    public private(set) var rawTranscript: String?
    public private(set) var formattedText: String?
    /// True when insertion is proceeding with the raw transcript because LLM
    /// formatting failed or was rejected by validation (invariant 2).
    public private(set) var degradedToRaw = false
    public private(set) var insertResult: InsertResult?
    public private(set) var cancelReason: CancelReason?

    // MARK: Seams

    private let now: @Sendable () -> Date
    private let logger: DictationEventLogger

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        logger: DictationEventLogger = NoopDictationEventLogger()
    ) {
        self.now = now
        self.logger = logger
        (states, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        stateContinuation.yield(.idle)
    }

    deinit {
        stateContinuation.finish()
    }

    // MARK: Events (each is exactly one transition)

    /// Hotkey pressed; recording starts (connections already prewarmed).
    public func startRecording() throws {
        try apply(.recording)
        metrics.tKeyDown = now()
        metrics.tRecStart = now()
    }

    /// Hotkey released; end-of-utterance sent, awaiting the final transcript.
    public func endRecording() throws {
        try apply(.transcribing)
        metrics.tKeyUp = now()
    }

    /// Cancel a recording before it reaches STT (Esc, or misfire discard).
    /// After this the session is back to `idle` and no audio was sent to STT.
    public func cancel(reason: CancelReason) throws {
        try apply(.idle)
        cancelReason = reason
    }

    /// Final transcript received; write-ahead to history happens here (§10.1).
    public func receiveFinalTranscript(_ transcript: String) throws {
        try apply(.formatting)
        metrics.tSTTFinal = now()
        rawTranscript = transcript
    }

    /// STT is dead after a batch resend; surface the retry UI (§10.2).
    public func sttFailed() throws {
        try apply(.error)
    }

    /// Stamp the first LLM token time. Does not change state (the Formatter
    /// calls this while in `formatting`); ignored in any other state.
    public func noteFirstLLMToken() {
        guard state == .formatting else { return }
        if metrics.tLLMFirstToken == nil { metrics.tLLMFirstToken = now() }
    }

    /// Formatting resolved. `degraded == true` means the raw transcript is
    /// being inserted because formatting failed/was rejected (invariant 2).
    public func beginInsertion(text: String, degraded: Bool) throws {
        try apply(.inserting)
        metrics.tLLMDone = now()
        formattedText = text
        degradedToRaw = degraded
    }

    /// Insertion resolved (pasted, fell back to clipboard, or blocked).
    public func completeInsertion(result: InsertResult) throws {
        try apply(.done)
        metrics.tInsertDone = now()
        insertResult = result
    }

    /// From `error`, return to `idle` for a retry.
    public func retry() throws {
        try apply(.idle)
    }

    /// From `done`, return to `idle`, ready for the next utterance.
    public func finish() throws {
        try apply(.idle)
    }

    // MARK: Transition core

    private func apply(_ next: DictationState) throws {
        guard state.canTransition(to: next) else {
            logger.illegalTransition(from: state, to: next)
            throw DictationError.illegalTransition(from: state, to: next)
        }
        state = next
        stateContinuation.yield(next)
    }
}
