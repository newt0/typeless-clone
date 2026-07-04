import Foundation

/// Writing-style setting for block [3] (Design §5.2).
public enum WritingStyle: String, Sendable, CaseIterable {
    /// Follow the transcript; unify a mixed transcript to desu/masu.
    case auto
    /// Force ですます.
    case desuMasu
    /// Force である.
    case dearu
}

/// One personal-dictionary term (Design §5.2 [4], FR-05). The same entries feed
/// STT keyword boost (M4/M8).
public struct DictionaryEntry: Sendable, Equatable {
    /// Canonical spelling to always use in the output.
    public let surface: String
    /// Reading (yomi), optional.
    public let reading: String?
    /// Freeform note, optional.
    public let note: String?

    public init(surface: String, reading: String? = nil, note: String? = nil) {
        self.surface = surface
        self.reading = reading
        self.note = note
    }
}

/// The assembled prompt handed to an ``LLMClient`` (M6-T1).
public struct AssembledPrompt: Sendable, Equatable {
    /// System prompt: blocks [1]–[5], stable-to-volatile for cache friendliness.
    public let system: String
    /// User message: block [6], the transcript wrapped in `<transcript>` tags.
    public let user: String
    /// Template version recorded with the dictation (Design §5.6).
    public let templateVersion: String
}

/// Builds the system/user prompt from the template + per-request inputs
/// (Design §5.2; plan M6-T2). Pure and deterministic.
public struct PromptAssembler: Sendable {
    private let template: PromptTemplate

    public init(template: PromptTemplate = .current) {
        self.template = template
    }

    public func assemble(
        transcript: String,
        style: WritingStyle = .auto,
        dictionary: [DictionaryEntry] = [],
        frontmostApp: String? = nil
    ) -> AssembledPrompt {
        // Blocks [1][2] are the stable cache prefix; [3][4][5] are per-user /
        // per-request; the transcript is isolated in the user message [6].
        let system = [
            template.roleRules,
            template.formattingRules,
            styleBlock(style),
            dictionaryBlock(dictionary),
            appContextBlock(frontmostApp),
        ].joined(separator: "\n\n")

        let user = "<transcript>\n\(sanitize(transcript))\n</transcript>"

        return AssembledPrompt(system: system, user: user, templateVersion: template.version)
    }

    // MARK: Block builders

    private func styleBlock(_ style: WritingStyle) -> String {
        switch style {
        case .auto:
            return "文体設定: 自動。話者の文体に従う。ですます調とである調が混在する場合はですます調に統一する。"
        case .desuMasu:
            return "文体設定: ですます調に統一する。"
        case .dearu:
            return "文体設定: である調に統一する。"
        }
    }

    private func dictionaryBlock(_ entries: [DictionaryEntry]) -> String {
        guard !entries.isEmpty else {
            return "用語辞書: （登録なし）"
        }
        let lines = entries.map { entry -> String in
            var line = "- \(entry.surface)"
            if let reading = entry.reading, !reading.isEmpty { line += "（読み: \(reading)）" }
            if let note = entry.note, !note.isEmpty { line += " — \(note)" }
            return line
        }
        return (["用語辞書（以下の表記を必ず用いる）:"] + lines).joined(separator: "\n")
    }

    private func appContextBlock(_ frontmostApp: String?) -> String {
        let name = frontmostApp?.isEmpty == false ? frontmostApp! : "不明"
        return """
        入力先アプリ: \(name)
        （ターミナルやコードエディタが入力先の場合は、装飾のないプレーンテキストとし、改行は最小限にする。）
        """
    }

    /// Neutralize any literal `<transcript>` tags in the transcript so spoken
    /// content can't forge the injection boundary. STT output never contains
    /// real XML tags, so this removes nothing meaningful.
    private func sanitize(_ transcript: String) -> String {
        transcript
            .replacingOccurrences(of: "<transcript>", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "</transcript>", with: "", options: .caseInsensitive)
    }
}
