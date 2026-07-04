import Testing
@testable import KoeCore

@Suite("OutputValidator")
struct OutputValidatorTests {
    private let validator = OutputValidator()

    @Test("normal cleanup is accepted (trimmed)")
    func acceptsNormal() {
        let decision = validator.validate(raw: "えーと明日送ります", formatted: "  明日送ります。 ")
        #expect(decision == .accept("明日送ります。"))
    }

    @Test("empty or whitespace output degrades")
    func emptyDegrades() {
        #expect(validator.validate(raw: "資料を送る", formatted: "") == .degrade(reason: .emptyOutput))
        #expect(validator.validate(raw: "資料を送る", formatted: "   \n ") == .degrade(reason: .emptyOutput))
    }

    @Test("excessive shrink is flagged as summarization")
    func shrinkDegrades() {
        let raw = String(repeating: "本", count: 100)
        let formatted = String(repeating: "本", count: 50) // 50% shrink > 30% limit
        #expect(validator.validate(raw: raw, formatted: formatted) == .degrade(reason: .suspectedSummarization))
    }

    @Test("shrink within the limit is accepted")
    func moderateShrinkAccepted() {
        let raw = String(repeating: "本", count: 100)
        let formatted = String(repeating: "本", count: 80) // 20% shrink < 30%
        #expect(validator.validate(raw: raw, formatted: formatted) == .accept(formatted))
    }

    @Test("leaked prompt fragments degrade")
    func promptLeakageDegrades() {
        #expect(validator.validate(raw: "x", formatted: "<transcript>x</transcript>") == .degrade(reason: .instructionLeakage))
        #expect(validator.validate(raw: "x", formatted: "整形規則にしたがって整えました") == .degrade(reason: .instructionLeakage))
    }

    @Test("code fences and quote-wrapped output degrade")
    func wrappingDegrades() {
        #expect(validator.validate(raw: "x", formatted: "```\n明日送ります\n```") == .degrade(reason: .instructionLeakage))
        #expect(validator.validate(raw: "x", formatted: "\"明日送ります\"") == .degrade(reason: .instructionLeakage))
    }

    @Test("legitimate Japanese quoting is not flagged")
    func japaneseQuotesAccepted() {
        let out = "「わかりました」と伝えてください。"
        #expect(validator.validate(raw: "わかりましたと伝えて", formatted: out) == .accept(out))
    }
}
