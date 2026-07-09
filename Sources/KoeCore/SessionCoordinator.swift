import Foundation

/// Final disposition of one dictation.
public enum DictationOutcome: Sendable, Equatable {
    case completed(InsertResult)
    case failed
}

/// Orchestrates one dictation per hotkey press (Design §7.2, §10.4; plan M1-T2).
///
/// Each utterance runs its record → transcribe → format pipeline concurrently
/// with other utterances, but the *insertion* stage is serialized through an
/// ``InsertionSerializer`` so text always lands in press order. The coordinator
/// drives the ``DictationSession`` state machine and performs write-ahead
/// history so nothing is lost even if a later stage fails (invariant 1).
public actor SessionCoordinator {
    private let audio: AudioCapturing
    private let stt: Transcribing
    private let formatter: Formatting
    private let inserter: TextInserting
    private let history: HistoryWriting
    private let focus: ContextProviding
    private let serializer: InsertionSerializer
    private let now: @Sendable () -> Date
    private let logger: DictationEventLogger

    public init(
        audio: AudioCapturing,
        stt: Transcribing,
        formatter: Formatting,
        inserter: TextInserting,
        history: HistoryWriting,
        focus: ContextProviding,
        serializer: InsertionSerializer = InsertionSerializer(),
        now: @escaping @Sendable () -> Date = { Date() },
        logger: DictationEventLogger = NoopDictationEventLogger()
    ) {
        self.audio = audio
        self.stt = stt
        self.formatter = formatter
        self.inserter = inserter
        self.history = history
        self.focus = focus
        self.serializer = serializer
        self.now = now
        self.logger = logger
    }

    /// Begin one utterance. Reserves the FIFO ticket, then returns a running
    /// task for the rest of the pipeline so pipelines overlap while insertion
    /// stays serialized.
    ///
    /// Ordering contract: the ticket reservation crosses an actor hop, so press
    /// order maps to ticket order only if the caller `await`s each
    /// `startUtterance()` before starting the next. A serial main-actor hotkey
    /// flow that awaits per press satisfies this; firing unawaited
    /// `Task { startUtterance() }`s per press would NOT (two such tasks may
    /// reach the serializer in either order). See the pipeline-wiring note in
    /// STATUS.md.
    @discardableResult
    public func startUtterance() async -> Task<DictationOutcome, Never> {
        // Captured at press time, per utterance, so two overlapping dictations
        // each carry the app they were spoken into (M5-T2 review note). The
        // focus read is independent of the ticket, so both hops run in
        // parallel; the caller-side await-per-press contract (doc above) is
        // what orders tickets, not anything inside this method.
        async let bundleID = focus.frontmostBundleID()
        let context = UtteranceContext(
            index: await serializer.reserve(),
            recordingBundleID: await bundleID
        )
        return Task { await self.run(context) }
    }

    private func run(_ context: UtteranceContext) async -> DictationOutcome {
        let session = DictationSession(now: now, logger: logger)
        let outcome = await runStages(session, context)
        // Release the FIFO slot exactly once, in ticket order, on every path —
        // so a cancelled/failed utterance never blocks the ones behind it
        // (invariant 1 / §10.4). If the stages never reached insertion, this
        // waits for this ticket's turn before releasing; otherwise `waitTurn`
        // returns immediately since the ticket is already being served.
        await serializer.waitTurn(context.index)
        await serializer.complete(context.index)
        return outcome
    }

    private func runStages(
        _ session: DictationSession,
        _ context: UtteranceContext
    ) async -> DictationOutcome {
        do {
            try await session.startRecording()
            let audioStream = try await audio.record(context)
            // Chunks flow to STT while the user is still speaking; the callback
            // fires when the mic stream is exhausted (key-up / session cap) so
            // the state machine leaves `recording` at true end-of-speech, not
            // at transcript-complete.
            let transcript = try await stt.transcribe(audioStream, context) {
                do {
                    try await session.endRecording()
                } catch {
                    // The callback can't rethrow; don't lose the signal — an
                    // illegal transition here is a state-machine bug, not a
                    // pipeline failure (invariant 4: event name only).
                    Log.error("end_recording_illegal", category: .session)
                }
            }
            try await session.receiveFinalTranscript(transcript)
            // Write-ahead: the raw transcript is now durable regardless of what
            // fails downstream (Design §10.1).
            let historyID = await history.recordFinalTranscript(transcript, context)

            let output = try await formatter.format(transcript, context)
            await history.updateFormatted(historyID, text: output.text)

            // Gate the only globally serialized stage on FIFO order.
            await serializer.waitTurn(context.index)
            try await session.beginInsertion(text: output.text, degraded: output.degraded)
            let result = try await inserter.insert(output, context)
            await history.updateInsertResult(historyID, result: result)
            try await session.completeInsertion(result: result)
            try await session.finish()
            return .completed(result)
        } catch {
            // No body text (invariant 4); stage-specific detail is logged where
            // the failure originates (STT/LLM/insertion adapters).
            Log.error("utterance_failed", category: .session)
            return .failed
        }
    }
}
