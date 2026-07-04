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
    private let serializer: InsertionSerializer
    private let now: @Sendable () -> Date
    private let logger: DictationEventLogger

    public init(
        audio: AudioCapturing,
        stt: Transcribing,
        formatter: Formatting,
        inserter: TextInserting,
        history: HistoryWriting,
        serializer: InsertionSerializer = InsertionSerializer(),
        now: @escaping @Sendable () -> Date = { Date() },
        logger: DictationEventLogger = NoopDictationEventLogger()
    ) {
        self.audio = audio
        self.stt = stt
        self.formatter = formatter
        self.inserter = inserter
        self.history = history
        self.serializer = serializer
        self.now = now
        self.logger = logger
    }

    /// Begin one utterance. Reserves the FIFO ticket synchronously (in call
    /// order) and returns a running task for the rest of the pipeline, so
    /// callers preserve press order while pipelines overlap.
    @discardableResult
    public func startUtterance() async -> Task<DictationOutcome, Never> {
        let context = UtteranceContext(index: await serializer.reserve())
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
            let captured = try await audio.record(context)
            try await session.endRecording()

            let transcript = try await stt.transcribe(captured, context)
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
            return .failed
        }
    }
}
