import Foundation

/// Ties the formatting pipeline together (Design §5.1; plan M6): assemble the
/// prompt, call the LLM, validate the output, and degrade to the raw transcript
/// on any failure (invariant 2). Conforms to the ``Formatting`` seam so the
/// session coordinator can use it directly.
///
/// P0 formats the transcript as a single request; long-form chunking
/// (`TranscriptChunker`) is integrated in a follow-up.
public struct LLMFormatter: Formatting {
    private let client: LLMClient
    private let assembler: PromptAssembler
    private let validator: OutputValidator
    private let style: WritingStyle
    private let dictionary: [DictionaryEntry]
    private let frontmostApp: @Sendable () -> String?
    /// Total-time bound on one LLM request (Design §10.3 ladder); exceeding it
    /// degrades to the raw transcript instead of waiting out URLSession's own
    /// (much longer) timeout. Injectable for tests.
    private let timeout: Duration

    public init(
        client: LLMClient,
        assembler: PromptAssembler = PromptAssembler(),
        validator: OutputValidator = OutputValidator(),
        style: WritingStyle = .auto,
        dictionary: [DictionaryEntry] = [],
        frontmostApp: @escaping @Sendable () -> String? = { nil },
        timeout: Duration = KoeConstants.llmTotalTimeout
    ) {
        self.client = client
        self.assembler = assembler
        self.validator = validator
        self.style = style
        self.dictionary = dictionary
        self.frontmostApp = frontmostApp
        self.timeout = timeout
    }

    public func format(_ transcript: String, _ context: UtteranceContext) async -> PipelineOutput {
        let prompt = assembler.assemble(
            transcript: transcript,
            style: style,
            dictionary: dictionary,
            frontmostApp: frontmostApp()
        )
        do {
            let raw = try await Self.completeBounded(
                client, system: prompt.system, user: prompt.user, timeout: timeout
            )
            switch validator.validate(raw: transcript, formatted: raw) {
            case .accept(let text):
                return PipelineOutput(text: text, degraded: false)
            case .degrade(let reason):
                Log.event("format_degraded", category: .llm, code: reason.logCode)
                return PipelineOutput(text: transcript, degraded: true)
            }
        } catch {
            // LLM error → insert the raw transcript rather than losing text.
            if case LLMError.timeout = error {
                Log.error("format_llm_timeout", category: .llm)
            } else {
                Log.error("format_llm_failed", category: .llm)
            }
            return PipelineOutput(text: transcript, degraded: true)
        }
    }

    /// Race the request against the total-time bound (Design §10.3, the
    /// `llmTotalTimeout` leg — the TTFT/retry leg needs token streaming and
    /// lands with it). On timeout the in-flight request is cancelled and
    /// ``LLMError/timeout`` is thrown; the caller degrades (invariant 2).
    private static func completeBounded(
        _ client: LLMClient, system: String, user: String, timeout: Duration
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await client.complete(system: system, user: user) }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let text = first else {
                throw LLMError.timeout
            }
            return text
        }
    }
}

private extension DegradeReason {
    /// Numeric code for logging (invariant 4: no body text).
    var logCode: Int {
        switch self {
        case .emptyOutput: return 1
        case .suspectedSummarization: return 2
        case .instructionLeakage: return 3
        }
    }
}
