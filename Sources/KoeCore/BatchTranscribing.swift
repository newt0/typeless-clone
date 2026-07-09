import Foundation

/// One-shot transcription of a complete utterance's audio via the provider's
/// batch/REST endpoint (plan M4-T3; Design §10.2). The recovery path when the
/// streaming socket dies or the finals never arrive: slower, but the audio is
/// already fully captured, so correctness beats latency here.
public protocol BatchTranscribing: Sendable {
    /// `wav`: complete 16kHz mono PCM16 audio, WAV-wrapped (``WAVEncoder``).
    func transcribe(wav: Data, vocab: [STTVocabTerm]) async throws -> String
}

/// Session-lifetime storage for audio that could not be transcribed even by
/// the batch resend (plan M4-T3 double-fault). P0 scope: survives within the
/// app run for the HUD retry button; discarded on restart (the history row
/// remains as the audit trail).
public protocol UntranscribedAudioStoring: Sendable {
    /// Persist the WAV; returns an opaque id, or nil when persisting failed
    /// (the failure is then surfaced without a retry handle — the transcript
    /// is gone, which is exactly what the history row records).
    func save(wav: Data) async -> String?
    func load(id: String) async -> Data?
    func delete(id: String) async
}

/// What the HUD needs to offer a retry after a double-fault: the stored audio
/// and the history row that marks the untranscribed session (deleted when a
/// retry finally lands the text).
public struct RecoveryHandle: Sendable, Equatable {
    public let audioID: String
    public let historyID: UUID
    public init(audioID: String, historyID: UUID) {
        self.audioID = audioID
        self.historyID = historyID
    }
}
