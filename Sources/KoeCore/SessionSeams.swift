import Foundation

/// Per-utterance identity threaded through the pipeline stages.
/// `index` is the FIFO ticket (Design §10.4) — stable across the utterance's
/// lifetime and usable by stages for logging/metrics.
public struct UtteranceContext: Sendable, Equatable {
    public let index: Int
    /// Frontmost app bundle id captured when this utterance's recording began.
    /// Feeds both the insertion app-changed guard (M5-T2 review note: a single
    /// shared closure could not distinguish two overlapping utterances) and the
    /// LLM prompt's app-context block — the app the text is meant to land in.
    public let recordingBundleID: String?
    public init(index: Int, recordingBundleID: String? = nil) {
        self.index = index
        self.recordingBundleID = recordingBundleID
    }
}

/// The formatted result ready for insertion.
public struct PipelineOutput: Sendable, Equatable {
    public let text: String
    /// True when `text` is the raw transcript because formatting failed/was
    /// rejected (invariant 2).
    public let degraded: Bool
    public init(text: String, degraded: Bool) {
        self.text = text
        self.degraded = degraded
    }
}

// MARK: Collaborator seams (plan M1-T2)
//
// Narrow protocols the coordinator orchestrates; concrete implementations land
// in later milestones (noted per protocol). Naming is stage-oriented; the M4
// streaming `STTClient` protocol will be adapted behind ``Transcribing`` rather
// than being the coordinator's seam (see docs/decisions.md 2026-07-04).

/// Hands the coordinator one utterance's live audio: ~40ms PCM16 chunks that
/// finish when the mic stops (key-up or session cap). Streaming — not a
/// materialized blob — so STT receives audio while the user is still speaking
/// and key-up→final latency stays inside the §10.3 ladder. A mid-capture
/// fault (device died, HAL error) must surface as a thrown stream error, NOT
/// a plain `finish()`: a silent early end is indistinguishable from key-up
/// and would insert a truncated utterance as success (invariant 1).
public protocol AudioCapturing: Sendable {
    func record(_ context: UtteranceContext) async throws -> AsyncThrowingStream<Data, any Error>
}

/// Live audio → final transcript. Backed by an M4 `STTClient` adapter.
public protocol Transcribing: Sendable {
    /// `onRecordingEnded` fires exactly once per utterance, before `transcribe`
    /// returns or throws — normally at true end-of-speech (mic stream
    /// exhausted), but also on early provider finalization and on failure — so
    /// the coordinator can always advance the session state machine out of
    /// `recording` regardless of which side ended the utterance.
    func transcribe(
        _ audio: AsyncThrowingStream<Data, any Error>,
        _ context: UtteranceContext,
        onRecordingEnded: @escaping @Sendable () async -> Void
    ) async throws -> String
}

/// Transcript → formatted output (with degradation flag). Implemented in M6.
public protocol Formatting: Sendable {
    func format(_ transcript: String, _ context: UtteranceContext) async throws -> PipelineOutput
}

/// Writes the formatted text into the focused field. Implemented in M5.
public protocol TextInserting: Sendable {
    func insert(_ output: PipelineOutput, _ context: UtteranceContext) async throws -> InsertResult
}

/// Frontmost-app / focus reads for preflight. Implemented in M5 (read-only AX).
public protocol ContextProviding: Sendable {
    func frontmostBundleID() async -> String?
}

/// Write-ahead history so no utterance is lost (Design §10.1, invariant 1).
/// The three calls happen at final-transcript, formatting, and insertion.
public protocol HistoryWriting: Sendable {
    /// Insert the row the moment the final transcript arrives; returns its id.
    func recordFinalTranscript(_ transcript: String, _ context: UtteranceContext) async -> UUID
    /// Update the row with the formatted text.
    func updateFormatted(_ id: UUID, text: String) async
    /// Update the row with the final insertion outcome.
    func updateInsertResult(_ id: UUID, result: InsertResult) async
    /// Record an utterance whose audio could not be transcribed at all (M4-T3
    /// double-fault) — the audit trail behind the HUD retry button.
    func recordUntranscribedSession(_ context: UtteranceContext) async -> UUID
    /// Remove a row — used when a successful retry replaces its
    /// untranscribed-session marker.
    func deleteRecord(_ id: UUID) async
}
