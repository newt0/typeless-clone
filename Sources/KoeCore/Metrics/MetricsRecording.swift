import Foundation

/// One dictation's numeric outcome for the local metrics pipeline (plan
/// M10-T2; Design §8.4). Strictly body-text-free (invariant 4): durations,
/// outcome kind, and the target app id — never transcripts or formatted text.
public struct DictationSample: Sendable, Equatable {
    public let createdAt: Date
    public let utterance: Int
    /// `InsertResult.rawValue`, or `"failed"`.
    public let outcome: String
    /// True for M4-T3 HUD retries: their "recording" timestamps are synthetic
    /// (stamped at retry-click), so latency views must exclude them.
    public let isRetry: Bool
    public let degraded: Bool
    public let appBundleID: String?
    /// key-up → STT final (budget segment 1), ms.
    public let sttFinalizeMs: Int?
    /// STT final → LLM done (segments 2+3 combined — TTFT needs token
    /// streaming, deferred with it), ms.
    public let llmMs: Int?
    /// LLM done → insertion complete (segment 5), ms.
    public let insertionMs: Int?
    /// key-up → inserted (the P50 ≤1.5s / P95 ≤3.0s target), ms.
    public let endToEndMs: Int?

    public init(
        createdAt: Date,
        utterance: Int,
        outcome: String,
        isRetry: Bool = false,
        degraded: Bool,
        appBundleID: String?,
        metrics: DictationMetrics
    ) {
        self.createdAt = createdAt
        self.utterance = utterance
        self.outcome = outcome
        self.isRetry = isRetry
        self.degraded = degraded
        self.appBundleID = appBundleID
        self.sttFinalizeMs = DictationMetrics.gapMs(metrics.tKeyUp, metrics.tSTTFinal)
        self.llmMs = DictationMetrics.gapMs(metrics.tSTTFinal, metrics.tLLMDone)
        self.insertionMs = DictationMetrics.gapMs(metrics.tLLMDone, metrics.tInsertDone)
        self.endToEndMs = DictationMetrics.gapMs(metrics.tKeyUp, metrics.tInsertDone)
    }
}

extension DictationMetrics {
    /// Single Date-gap → ms conversion (review finding: two copies diverged).
    /// Floored at 0: a backward wall-clock jump mid-utterance must not persist
    /// a negative duration into the stats.
    static func gapMs(_ start: Date?, _ end: Date?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }
}

/// Sink for per-dictation samples (plan M10-T2). The app-layer implementation
/// owns the opt-out check and the storage.
public protocol MetricsRecording: Sendable {
    func record(_ sample: DictationSample) async
}

/// Nearest-rank percentiles for the stats view (pure, testable).
public enum Percentiles {
    /// Nearest-rank percentile over unsorted values; `nil` when empty.
    public static func value(_ values: [Int], percentile: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((percentile / 100 * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }
}
