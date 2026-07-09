import Foundation

/// Centralized tunable constants (Design §6, §8, §10; plan M0-T1).
///
/// Every value marked `[tune in Phase 0]` is a provisional initial value that
/// Phase 0 spikes (`docs/plan/01-phase0-spikes.md`) will measure and confirm.
/// Keep all such numbers here so tuning is a single-file change.
public enum KoeConstants {
    // MARK: Insertion timing (Design §6.3) — [tune in Phase 0 / S1]

    /// Delay between writing the pasteboard and posting the synthetic Cmd+V.
    public static let pastePreDelay: Duration = .milliseconds(100)
    /// Wait after paste before restoring the clipboard snapshot.
    public static let clipboardRestoreWait: Duration = .milliseconds(300)
    /// Interval between synthesized key events in the Cmd+V sequence.
    public static let synthKeyInterval: Duration = .milliseconds(10)
    /// Upper bound for one synchronous AX read (preflight / paste verification).
    /// The system default (~6s) would hang the main actor on an unresponsive
    /// target app; a timed-out read takes the existing "AX unreadable" path.
    /// Deliberately generous — NOT the insertion latency budget: timed-out
    /// secure-field/verify reads fail *open* (proceed / assume success), so this
    /// bound only exists to convert multi-second hangs into the nil path. Apps
    /// that are merely slow (heavy Electron ~400ms) must still be read, or the
    /// invariant-3 secure guard and invariant-1 verify net silently weaken.
    public static let axReadTimeout: Duration = .seconds(1)

    // MARK: Session control (Design §7.2)

    /// Press shorter than this with no audio is treated as a misfire and
    /// discarded without contacting STT.
    public static let misfireThreshold: Duration = .milliseconds(300)
    /// Max in-memory session audio kept for STT resend before recording stops.
    public static let maxSessionRecording: Duration = .seconds(20 * 60)

    // MARK: Audio capture (Design §7.4)

    /// Target duration of each PCM16 chunk streamed to STT. 20–50ms keeps
    /// key-up→final latency low without flooding the socket; the input tap is
    /// sized from this (`AudioFormatSpec/frameCount(for:atSampleRate:)`).
    public static let audioChunkDuration: Duration = .milliseconds(40)

    // MARK: Hotkey (Design §7.3)

    /// How often the CGEventTap liveness check runs (tap validity +
    /// `AXIsProcessTrusted()`). Belt-and-suspenders on top of the immediate
    /// `tapDisabled*` re-enable, and the path that detects Accessibility
    /// revocation.
    public static let tapLivenessInterval: Duration = .seconds(60)

    // MARK: Formatting pipeline (Design §5.1)

    /// Transcripts longer than this (characters) are chunked and formatted in
    /// parallel, then joined for a single insertion.
    public static let longFormChunkThreshold = 500
    /// Target chunk size when splitting long-form transcripts at sentence
    /// boundaries.
    public static let longFormChunkTarget = 400
    /// Output shorter than input by more than this ratio is treated as a
    /// summarization failure and degraded to the raw transcript (Design §5.1).
    public static let summarizationShrinkLimit = 0.30

    // MARK: Timeout ladder (Design §10.3) — [tune in Phase 0 / S4]

    /// STT WebSocket connect + ping-verification budget; exceeding treats the
    /// socket as unreachable (prewarm/beginUtterance fail rather than hang).
    public static let sttConnectTimeout: Duration = .seconds(5)
    /// key-up → STT final; exceeding triggers a single batch resend.
    public static let sttFinalTimeout: Duration = .seconds(2)
    /// Absolute bound on key-up → transcript-complete before the utterance is
    /// failed. A circuit breaker well above `sttFinalTimeout`'s resend trigger
    /// (which lands with M4-T3): a dead socket that accepted the audio but
    /// never confirms end-of-transcript would otherwise hang its utterance —
    /// and, since every FIFO ticket must complete, wedge insertion for every
    /// utterance behind it. The recording leg itself is unbounded by design
    /// (capped upstream by `maxSessionRecording`).
    public static let sttStallTimeout: Duration = .seconds(30)
    /// LLM time-to-first-token; exceeding triggers one retry then degradation.
    public static let llmTTFTTimeout: Duration = .milliseconds(1500)
    /// LLM total generation (per chunk when split); exceeding degrades to raw.
    public static let llmTotalTimeout: Duration = .seconds(6)
    /// Per insertion stage; exceeding advances to the next fallback path.
    public static let insertionStageTimeout: Duration = .milliseconds(500)

    // MARK: HUD (Design §7.5) — [tune at owner QA]

    /// "Done" flash before the panel hides.
    public static let hudDoneDwell: Duration = .milliseconds(700)
    /// Clipboard landing lingers — the user must notice "press ⌘V".
    public static let hudClipboardDwell: Duration = .seconds(4)
    /// Secure-block / failure / side-notice dwell.
    public static let hudNoticeDwell: Duration = .milliseconds(2500)
}
