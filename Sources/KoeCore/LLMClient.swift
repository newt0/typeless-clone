import Foundation

/// Errors from an ``LLMClient``.
public enum LLMError: Error, Equatable, Sendable {
    case network
    case http(status: Int)
    case malformedResponse
    case empty
}

/// Abstraction over the formatting LLM (Design §4.2; plan M6-T1). Adapters:
/// Gemini 2.5 Flash-Lite (primary), Claude Haiku 4.5 / Bedrock (fallback).
///
/// P0 is non-streaming: the whole completion is returned at once, which matches
/// the pipeline (insert once, invariant 6). Token streaming is a later TTFT
/// optimization (see docs/decisions.md).
public protocol LLMClient: Sendable {
    /// Run the formatting prompt and return the model's text output.
    func complete(system: String, user: String) async throws -> String
}
