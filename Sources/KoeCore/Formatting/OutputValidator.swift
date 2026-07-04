import Foundation

/// Why formatting was rejected in favor of the raw transcript (Design §5.1).
public enum DegradeReason: String, Sendable, Equatable {
    case emptyOutput
    case suspectedSummarization
    case instructionLeakage
}

/// Decision after validating an LLM formatting result.
public enum FormatterDecision: Sendable, Equatable {
    /// Formatted text is good; insert it.
    case accept(String)
    /// Reject it and insert the raw transcript instead (invariant 2).
    case degrade(reason: DegradeReason)
}

/// Post-processing check that guards against the LLM breaking the contract
/// (Design §5.1; plan M6-T3). Better to insert a slightly-rough raw transcript
/// than a summarized or corrupted output.
public struct OutputValidator: Sendable {
    /// Output shorter than `raw * (1 - shrinkLimit)` is treated as a summary.
    public let shrinkLimit: Double

    public init(shrinkLimit: Double = KoeConstants.summarizationShrinkLimit) {
        self.shrinkLimit = shrinkLimit
    }

    public func validate(raw: String, formatted: String) -> FormatterDecision {
        let trimmed = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .degrade(reason: .emptyOutput)
        }
        if hasInstructionLeakage(trimmed) {
            return .degrade(reason: .instructionLeakage)
        }
        if isSuspectedSummarization(raw: raw, formatted: trimmed) {
            return .degrade(reason: .suspectedSummarization)
        }
        return .accept(trimmed)
    }

    // MARK: Checks

    /// Fragments of our own prompt, code fences, or a whole output wrapped in
    /// double quotes — all signs the model leaked instructions or wrapped its
    /// answer instead of returning bare formatted text.
    private func hasInstructionLeakage(_ text: String) -> Bool {
        let markers = [
            "<transcript>", "</transcript>",
            "整形規則", "絶対規則", "文体設定:", "用語辞書", "入力先アプリ:",
        ]
        if markers.contains(where: text.contains) { return true }
        if text.hasPrefix("```") { return true }

        // Entire output wrapped in ASCII/curly double quotes. Japanese 「」 is
        // legitimate quoting, so it is not flagged.
        let wraps: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}")]
        if let first = text.first, let last = text.last, text.count >= 2 {
            if wraps.contains(where: { $0.0 == first && $0.1 == last }) { return true }
        }
        return false
    }

    private func isSuspectedSummarization(raw: String, formatted: String) -> Bool {
        guard raw.count > 0 else { return false }
        return Double(formatted.count) < Double(raw.count) * (1.0 - shrinkLimit)
    }
}
