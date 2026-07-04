import Foundation

/// A single event from a streaming speech-to-text session (Design §4.1; plan M4-T1).
///
/// The surface is deliberately narrow — three cases. Vendor-specific richness
/// (word timings, confidence, speaker labels) stays inside adapters; the
/// pipeline only needs live partials and the settling finals.
public enum STTEvent: Sendable, Equatable {
    /// An interim hypothesis for the current audio (may change). HUD live text.
    case partial(String)
    /// A settled transcript segment. Emitted per provider segment; the caller
    /// concatenates segments in arrival order to form the utterance transcript.
    case final(String)
    /// A terminal failure for this utterance; the stream finishes right after.
    case error(STTError)
}

/// Errors surfaced by an ``STTClient``.
public enum STTError: Error, Equatable, Sendable {
    /// Rejected credentials (HTTP 401/403 on the WebSocket upgrade).
    case auth
    /// Transport failure: handshake failed, or the socket dropped mid-session.
    case connection
    /// A provider-side error message (its `type`/`reason`, never body text).
    case server(type: String)
    /// A server frame we could not parse into a known message.
    case malformedResponse
    /// `send`/`endUtterance` called before a session was started.
    case notStarted
}

/// Streaming speech-to-text abstraction (Design §4.1). Adapters: Speechmatics
/// Enhanced RT (primary); Deepgram/Soniox as Phase-0 A/B candidates.
///
/// Lifecycle: ``prewarm()`` at app launch and on hotkey-down so speech never
/// pays TLS+WebSocket setup (~300ms, Design §8); ``beginUtterance(vocab:)`` on
/// speech start; ``send(audioChunk:)`` while speaking; ``endUtterance()`` at
/// key-up. Connection reuse/reconnect is the adapter's concern and stays off
/// this protocol — like ``LLMClient``, the P0 surface is intentionally minimal.
public protocol STTClient: Sendable {
    /// Establish or verify the connection ahead of speech. Idempotent: a no-op
    /// when a healthy connection already exists, a reconnect when idle-closed.
    func prewarm() async throws

    /// Start one utterance and return its live event stream. The personal
    /// dictionary (``STTVocabTerm``) is injected at session start; the adapter
    /// translates it to the provider's vocabulary-boost wire format.
    func beginUtterance(vocab: [STTVocabTerm]) async throws -> AsyncStream<STTEvent>

    /// Stream one audio chunk: 16kHz, mono, little-endian PCM16.
    func send(audioChunk: Data) async throws

    /// Signal end of speech. The adapter flushes buffered audio and awaits the
    /// remaining finals; the event stream finishes once the provider confirms
    /// end-of-transcript.
    func endUtterance() async throws
}
