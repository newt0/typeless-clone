import Foundation

/// Final disposition of one dictation. A failure carries the M4-T3 recovery
/// handle when the utterance's audio survived a double-fault (HUD retry).
public enum DictationOutcome: Sendable, Equatable {
    case completed(InsertResult)
    case failed(recovery: RecoveryHandle?)
}

/// Re-runs the batch STT leg from persisted audio (M4-T3 HUD retry). The app
/// composes ``ResilientTranscriber`` behind this.
public protocol RecoveryRetrying: Sendable {
    func retryTranscribe(audioID: String) async throws -> String
    /// Discard the persisted audio once the WHOLE retry pipeline completed
    /// (transcript inserted) — never earlier, or a downstream failure strands
    /// a stale handle (review finding).
    func discardRecovered(audioID: String) async
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
    /// UI observation seam (M9 HUD); `nil` = headless (tests, no UI yet).
    private let ui: (any DictationUIObserving)?
    /// Batch retry seam (M4-T3); `nil` = retry unavailable.
    private let recovery: (any RecoveryRetrying)?
    /// Local metrics sink (M10-T2); `nil` = not recording.
    private let metricsSink: (any MetricsRecording)?
    /// Retries currently in flight, keyed by audio id — a double-tapped HUD
    /// button must not insert the same utterance twice (review finding).
    private var activeRetries: Set<String> = []

    public init(
        audio: AudioCapturing,
        stt: Transcribing,
        formatter: Formatting,
        inserter: TextInserting,
        history: HistoryWriting,
        focus: ContextProviding,
        ui: (any DictationUIObserving)? = nil,
        recovery: (any RecoveryRetrying)? = nil,
        metrics: (any MetricsRecording)? = nil,
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
        self.ui = ui
        self.recovery = recovery
        self.metricsSink = metrics
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

    /// Retry an unrecovered utterance from its persisted audio (M4-T3 HUD
    /// retry button). Reserves a fresh FIFO ticket. The audit row and stored
    /// WAV are deleted only after the WHOLE pipeline completed (transcript
    /// inserted) — a downstream failure keeps the same handle retryable with
    /// its audio intact (review finding). Returns `nil` when a retry for the
    /// same audio is already in flight (double-tap guard).
    @discardableResult
    public func startRetry(_ handle: RecoveryHandle) async -> Task<DictationOutcome, Never>? {
        guard activeRetries.insert(handle.audioID).inserted else {
            Log.event("retry_duplicate_ignored", category: .session)
            return nil
        }
        async let bundleID = focus.frontmostBundleID()
        let context = UtteranceContext(
            index: await serializer.reserve(),
            recordingBundleID: await bundleID
        )
        return Task {
            let outcome = await self.run(context) { session in
                guard let recovery = self.recovery else { throw UnrecoveredUtterance(audioID: nil) }
                // Synthetic transitions: there is no live mic for a retry, but
                // the lifecycle (and its observers) stay uniform.
                try await session.startRecording()
                try await session.endRecording()
                return try await recovery.retryTranscribe(audioID: handle.audioID)
            } failureRecovery: { error in
                // Keep the SAME handle alive unless the audio itself is gone.
                if let unrecovered = error as? UnrecoveredUtterance, unrecovered.audioID == nil {
                    return nil
                }
                return handle
            }
            if case .completed = outcome {
                await self.history.deleteRecord(handle.historyID)
                await self.recovery?.discardRecovered(audioID: handle.audioID)
            }
            await self.finishRetry(handle.audioID)
            return outcome
        }
    }

    private func finishRetry(_ audioID: String) {
        activeRetries.remove(audioID)
    }

    private func run(_ context: UtteranceContext) async -> DictationOutcome {
        await run(context) { session in
            try await session.startRecording()
            let audioStream = try await self.audio.record(context)
            // Chunks flow to STT while the user is still speaking; the callback
            // fires when the mic stream is exhausted (key-up / session cap) so
            // the state machine leaves `recording` at true end-of-speech, not
            // at transcript-complete.
            return try await self.stt.transcribe(audioStream, context) {
                do {
                    try await session.endRecording()
                } catch {
                    // The callback can't rethrow; don't lose the signal — an
                    // illegal transition here is a state-machine bug, not a
                    // pipeline failure (invariant 4: event name only).
                    Log.error("end_recording_illegal", category: .session)
                }
            }
        } failureRecovery: { error in
            guard let unrecovered = error as? UnrecoveredUtterance,
                  let audioID = unrecovered.audioID else { return nil }
            // The audio survived the double-fault: record the audit row and
            // hand the HUD a retry (M4-T3).
            let historyID = await self.history.recordUntranscribedSession(context)
            return RecoveryHandle(audioID: audioID, historyID: historyID)
        }
    }

    /// Shared lifecycle for live utterances and retries: `transcribe` yields
    /// the final transcript (driving the session's recording transitions);
    /// everything from write-ahead through insertion is identical.
    /// `failureRecovery` maps a stage error to the retry handle surfaced with
    /// the failure (`nil` = not retryable).
    private func run(
        _ context: UtteranceContext,
        transcribe: (DictationSession) async throws -> String,
        failureRecovery: (any Error) async -> RecoveryHandle?
    ) async -> DictationOutcome {
        let session = DictationSession(now: now, logger: logger)
        ui?.utteranceBegan(context, states: session.states)
        let outcome: DictationOutcome
        do {
            let transcript = try await transcribe(session)
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
            outcome = .completed(result)
        } catch {
            // No body text (invariant 4); stage-specific detail is logged where
            // the failure originates (STT/LLM/insertion adapters).
            Log.error("utterance_failed", category: .session)
            outcome = .failed(recovery: await failureRecovery(error))
        }
        switch outcome {
        case .completed(let result):
            ui?.utteranceLanded(context, result: result)
        case .failed(let recovery):
            ui?.utteranceFailed(context, recovery: recovery)
        }
        if let metricsSink {
            // Numeric outcome only (invariant 4); fire-and-forget so a slow
            // sink can never delay the FIFO release below.
            let outcomeLabel: String = switch outcome {
            case .completed(let result): result.rawValue
            case .failed: "failed"
            }
            let sample = DictationSample(
                createdAt: now(),
                utterance: context.index,
                outcome: outcomeLabel,
                degraded: await session.degradedToRaw,
                appBundleID: context.recordingBundleID,
                metrics: await session.metrics
            )
            Task { await metricsSink.record(sample) }
        }
        // Release the FIFO slot exactly once, in ticket order, on every path —
        // so a cancelled/failed utterance never blocks the ones behind it
        // (invariant 1 / §10.4). If the stages never reached insertion, this
        // waits for this ticket's turn before releasing; otherwise `waitTurn`
        // returns immediately since the ticket is already being served.
        await serializer.waitTurn(context.index)
        await serializer.complete(context.index)
        return outcome
    }
}
