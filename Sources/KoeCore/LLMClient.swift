import Foundation

/// Errors from an ``LLMClient``.
public enum LLMError: Error, Equatable, Sendable {
    case network
    case http(status: Int)
    case malformedResponse
    case empty
    /// The request exceeded ``KoeConstants/llmTotalTimeout`` (Design §10.3
    /// ladder) and was abandoned in favor of the raw transcript (invariant 2).
    case timeout
}

/// Abstraction over the formatting LLM (Design §4.2; plan M6-T1). Adapters:
/// Gemini 2.5 Flash-Lite (primary), Claude Haiku 4.5 / Bedrock (fallback).
///
/// P0 is non-streaming: the whole completion is returned at once, which matches
/// the pipeline (insert once, invariant 6). Token streaming is a later TTFT
/// optimization (see docs/decisions.md).
public protocol LLMClient: Sendable {
    /// Run the formatting prompt and return the model's text output.
    ///
    /// Adapters MUST be cancellation-responsive: unwind promptly (throwing
    /// `CancellationError`) when the calling task is cancelled. ``LLMFormatter``
    /// enforces the §10.3 total-time bound by cancelling this call, but the
    /// task-group cleanup awaits it — so an adapter whose transport ignores
    /// cancellation (e.g. a blocking SDK call) would stall the whole
    /// FIFO-serialized pipeline past the bound. `URLSession.data(for:)` already
    /// honors cancellation; a non-`URLSession` adapter must check
    /// `Task.isCancelled` / use a cancellation-aware transport.
    func complete(system: String, user: String) async throws -> String
}
