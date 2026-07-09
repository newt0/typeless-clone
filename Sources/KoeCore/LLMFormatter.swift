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
    /// Style and dictionary are providers, read per format call, so Settings
    /// changes (M10) apply to the next utterance without rebuilding the
    /// pipeline.
    private let style: @Sendable () -> WritingStyle
    private let dictionary: @Sendable () async -> [DictionaryEntry]
    /// Total-time bound on one LLM request (Design §10.3 ladder); exceeding it
    /// degrades to the raw transcript instead of waiting out URLSession's own
    /// (much longer) timeout. Injectable for tests.
    private let timeout: Duration

    public init(
        client: LLMClient,
        assembler: PromptAssembler = PromptAssembler(),
        validator: OutputValidator = OutputValidator(),
        styleProvider: @escaping @Sendable () -> WritingStyle,
        dictionaryProvider: @escaping @Sendable () async -> [DictionaryEntry],
        timeout: Duration = KoeConstants.llmTotalTimeout
    ) {
        self.client = client
        self.assembler = assembler
        self.validator = validator
        self.style = styleProvider
        self.dictionary = dictionaryProvider
        self.timeout = timeout
    }

    /// Fixed style/dictionary convenience (tests, simple composition).
    public init(
        client: LLMClient,
        assembler: PromptAssembler = PromptAssembler(),
        validator: OutputValidator = OutputValidator(),
        style: WritingStyle = .auto,
        dictionary: [DictionaryEntry] = [],
        timeout: Duration = KoeConstants.llmTotalTimeout
    ) {
        self.init(
            client: client,
            assembler: assembler,
            validator: validator,
            styleProvider: { style },
            dictionaryProvider: { dictionary },
            timeout: timeout
        )
    }

    public func format(_ transcript: String, _ context: UtteranceContext) async throws -> PipelineOutput {
        do {
            // Bound dictionary fetch + assembly + request by the §10.3
            // total-time leg — the dictionary provider is a DB read that can
            // stall behind a concurrent Settings edit, and it must not push
            // the utterance past the bound (review finding). App context
            // comes from the utterance itself (captured at press time).
            let client = self.client
            let assembler = self.assembler
            let style = self.style
            let dictionary = self.dictionary
            let raw = try await Deadline.run(timeout, onTimeout: { LLMError.timeout }) {
                let prompt = assembler.assemble(
                    transcript: transcript,
                    style: style(),
                    dictionary: await dictionary(),
                    frontmostApp: context.recordingBundleID
                )
                return try await client.complete(system: prompt.system, user: prompt.user)
            }
            switch validator.validate(raw: transcript, formatted: raw) {
            case .accept(let text):
                return PipelineOutput(text: text, degraded: false)
            case .degrade(let reason):
                Log.event("format_degraded", category: .llm, code: reason.logCode)
                return PipelineOutput(text: transcript, degraded: true)
            }
        } catch is CancellationError {
            // The utterance was cancelled (not a slow LLM). Abort so the pipeline
            // does not insert text the user cancelled; the coordinator treats the
            // throw as a failed utterance and never reaches the insert stage.
            throw CancellationError()
        } catch {
            // Real LLM error (incl. timeout) → insert the raw transcript rather
            // than losing text (invariant 2).
            if case LLMError.timeout = error {
                Log.error("format_llm_timeout", category: .llm)
            } else {
                Log.error("format_llm_failed", category: .llm)
            }
            return PipelineOutput(text: transcript, degraded: true)
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
