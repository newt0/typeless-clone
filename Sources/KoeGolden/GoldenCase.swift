import Foundation
import KoeCore

/// One golden-set case (plan S3-T1; Design §5.3, §5.5). The set is a durable
/// in-repo asset: it gates every prompt change (golden-set harness in the PR
/// gates) and the Phase 1 exit.
public struct GoldenCase: Codable, Sendable, Identifiable, Equatable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case filler            // 1 フィラー除去
        case selfCorrection    // 2 言い直し統合
        case repetition        // 3 重複圧縮
        case particle          // 4 助詞補完
        case style             // 5 文体統一
        case punctuation       // 6 句読点・段落
        case list              // 7 箇条書き化（してはいけない場合を含む）
        case itn               // 8 数字・日付・単位（慣用漢数字は保持）
        case termRestoration   // 9 和英混在の用語復元（辞書）
        case newlineCommand    // 10 「改行して」コマンド（これのみ）
        case compound          // 複合・長文
    }

    public let id: String
    public let category: Category
    /// `WritingStyle.rawValue`; nil = auto.
    public let style: String?
    /// Dictionary entries the case depends on (surface / reading).
    public let dictionary: [Entry]?
    public let input: String
    /// Substrings the output MUST contain.
    public let mustContain: [String]?
    /// Substrings the output MUST NOT contain.
    public let mustNotContain: [String]?
    /// Human rubric for the LLM-as-judge stage (S3-T2 b).
    public let rubric: String

    public struct Entry: Codable, Sendable, Equatable {
        public let surface: String
        public let reading: String?
    }

    public var writingStyle: WritingStyle {
        style.flatMap(WritingStyle.init(rawValue:)) ?? .auto
    }

    public var dictionaryEntries: [DictionaryEntry] {
        (dictionary ?? []).map { DictionaryEntry(surface: $0.surface, reading: $0.reading) }
    }
}

public enum GoldenSet {
    /// Load the bundled v1 set.
    public static func loadBundled() throws -> [GoldenCase] {
        guard let url = Bundle.module.url(forResource: "golden-set-v1", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([GoldenCase].self, from: Data(contentsOf: url))
    }
}

/// Stage (a) of S3-T2: deterministic checks that need no second model.
public enum GoldenChecks {
    public struct Failure: Sendable, Equatable, CustomStringConvertible {
        public let caseID: String
        public let reason: String
        public init(caseID: String, reason: String) {
            self.caseID = caseID
            self.reason = reason
        }
        public var description: String { "[\(caseID)] \(reason)" }
    }

    /// Evaluate one output. Empty array = pass.
    public static func evaluate(_ output: String, for goldenCase: GoldenCase) -> [Failure] {
        var failures: [Failure] = []
        func fail(_ reason: String) {
            failures.append(Failure(caseID: goldenCase.id, reason: reason))
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { fail("empty output") }

        // Preamble/quote leakage: the formatter must return the text alone.
        for marker in ["以下のように", "整形しました", "整形後", "出力:", "```"] {
            if trimmed.hasPrefix(marker) { fail("preamble/formatting leakage: \(marker)") }
        }

        // Summarization suspicion (§5.5). Production parity (OutputValidator
        // rejects >30% shrink) for categories that should preserve length;
        // the shrink-by-design categories (filler/repetition/self-correction,
        // and the newline command that deletes its own marker) get a looser
        // 50% floor — they compress legitimately, but halving the text still
        // signals content loss.
        let shrinkExempt: Set<GoldenCase.Category> = [.filler, .repetition, .selfCorrection, .newlineCommand]
        let floorRatio = shrinkExempt.contains(goldenCase.category) ? 0.5 : 0.7
        let inputCount = goldenCase.input.count
        if inputCount > 0, Double(trimmed.count) < Double(inputCount) * floorRatio {
            fail("suspicious shrink: \(inputCount) → \(trimmed.count) chars (floor \(floorRatio))")
        }

        for needle in goldenCase.mustContain ?? [] where !trimmed.contains(needle) {
            fail("missing required substring: \(needle)")
        }
        for needle in goldenCase.mustNotContain ?? [] where trimmed.contains(needle) {
            fail("contains forbidden substring: \(needle)")
        }

        // (Dictionary spelling compliance rides mustContain: cases list the
        // registered surface there, so a separate gated loop could never fire
        // — removed as dead logic per review.)

        return failures
    }
}
