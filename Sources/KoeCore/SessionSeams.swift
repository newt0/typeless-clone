import Foundation

/// Per-utterance identity threaded through the pipeline stages.
/// `index` is the FIFO ticket (Design §10.4) — stable across the utterance's
/// lifetime and usable by stages for logging/metrics.
public struct UtteranceContext: Sendable, Equatable {
    public let index: Int
    public init(index: Int) { self.index = index }
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

/// Captures audio for one utterance. Refined in M3 (streaming, device-switch).
public protocol AudioCapturing: Sendable {
    func record(_ context: UtteranceContext) async throws -> Data
}

/// Audio → final transcript. Backed by an M4 `STTClient` adapter.
public protocol Transcribing: Sendable {
    func transcribe(_ audio: Data, _ context: UtteranceContext) async throws -> String
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
}
