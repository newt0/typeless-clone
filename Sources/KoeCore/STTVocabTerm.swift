import Foundation

/// A provider-agnostic vocabulary hint for STT keyword boosting (FR-05).
///
/// The personal dictionary produces these; each STT adapter (M4) translates
/// them to its wire format — e.g. Speechmatics `additional_vocab` with
/// `sounds_like` in full-width kana. Any provider-specific normalization of
/// `soundsLike` (kana width, casing) is the adapter's responsibility, so this
/// type stays neutral.
public struct STTVocabTerm: Sendable, Equatable {
    /// The surface form to bias recognition toward.
    public let content: String
    /// Optional pronunciation hints (readings).
    public let soundsLike: [String]

    public init(content: String, soundsLike: [String] = []) {
        self.content = content
        self.soundsLike = soundsLike
    }
}
