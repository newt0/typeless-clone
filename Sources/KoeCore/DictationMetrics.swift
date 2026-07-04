import Foundation

/// Per-dictation stage timestamps for the latency budget (Design §8.4).
///
/// Only numeric/temporal data — never transcript or formatted body text
/// (invariant 4, `docs/plan/00-overview.md`). The state machine stamps the
/// fields it knows; ``tLLMFirstToken`` is stamped by the Formatter during the
/// `formatting` state.
public struct DictationMetrics: Sendable, Equatable {
    public var tKeyDown: Date?
    public var tRecStart: Date?
    public var tKeyUp: Date?
    public var tSTTFinal: Date?
    public var tLLMFirstToken: Date?
    public var tLLMDone: Date?
    public var tInsertDone: Date?

    public init() {}

    // MARK: Derived segment durations (nil until both endpoints are stamped)

    /// key-up → STT final (budget segment 1).
    public var sttFinalizeDuration: Duration? { Self.gap(tKeyUp, tSTTFinal) }
    /// STT final → first LLM token (TTFT, budget segment 2).
    public var llmTTFT: Duration? { Self.gap(tSTTFinal, tLLMFirstToken) }
    /// First token → LLM done (generation, budget segment 3).
    public var llmGeneration: Duration? { Self.gap(tLLMFirstToken, tLLMDone) }
    /// LLM done → insertion complete (budget segment 5).
    public var insertionDuration: Duration? { Self.gap(tLLMDone, tInsertDone) }
    /// Full end-of-speech → inserted (the P50/P95 target metric).
    public var endToEnd: Duration? { Self.gap(tKeyUp, tInsertDone) }

    private static func gap(_ start: Date?, _ end: Date?) -> Duration? {
        guard let start, let end else { return nil }
        return .seconds(end.timeIntervalSince(start))
    }
}
