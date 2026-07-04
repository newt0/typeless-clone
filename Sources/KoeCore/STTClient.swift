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
    /// `send`/`endUtterance` called before a session was started (or after it
    /// ended).
    case notStarted
    /// `beginUtterance` called while another begin is still in flight.
    case busy

    /// Normalize an arbitrary transport error into the STT taxonomy: pass an
    /// existing ``STTError`` through, map anything else to ``connection``.
    public static func from(_ error: Error) -> STTError {
        (error as? STTError) ?? .connection
    }
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
    /// Establish the connection ahead of speech so the first utterance doesn't
    /// pay TLS+WebSocket setup. Idempotent: a no-op when a connection already
    /// exists. If that connection has since idle-closed, ``beginUtterance`` (not
    /// prewarm) transparently reconnects, since only a live session detects the
    /// drop.
    func prewarm() async throws

    /// Start one utterance and return its live event stream. The personal
    /// dictionary (``STTVocabTerm``) is injected at session start; the adapter
    /// translates it to the provider's vocabulary-boost wire format. If the
    /// prewarmed socket has since closed, it reconnects once transparently.
    func beginUtterance(vocab: [STTVocabTerm]) async throws -> AsyncStream<STTEvent>

    /// Stream one audio chunk: 16kHz, mono, little-endian PCM16.
    func send(audioChunk: Data) async throws

    /// Signal end of speech. The adapter flushes buffered audio and awaits the
    /// remaining finals; the event stream finishes once the provider confirms
    /// end-of-transcript.
    func endUtterance() async throws
}
