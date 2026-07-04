import Foundation
import GRDB
import KoeCore

/// One personal-dictionary entry (Design §5.2 [4], FR-05). A single stored term
/// feeds both consumers via the serializers below: the LLM prompt (block [4])
/// and STT keyword boost.
public struct DictionaryTerm: Codable, Sendable, Equatable, Identifiable,
                              FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    /// Canonical spelling the output must use, e.g. "Claude Code".
    public var surface: String
    /// Reading (yomi), used as an STT pronunciation hint.
    public var reading: String?
    /// Freeform note.
    public var notes: String?
    public var createdAt: Date

    public static let databaseTableName = "dictionary"

    public init(
        id: Int64? = nil,
        surface: String,
        reading: String? = nil,
        notes: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.surface = surface
        self.reading = reading
        self.notes = notes
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: Serializers (pure — testable without a database)

    /// For the LLM prompt block [4] (`PromptAssembler`).
    public var promptEntry: DictionaryEntry {
        DictionaryEntry(surface: surface, reading: reading, note: notes)
    }

    /// For STT keyword boost. The reading, if present, becomes a `soundsLike`
    /// hint; provider-specific formatting is done by the STT adapter (M4).
    public var sttVocabTerm: STTVocabTerm {
        if let reading, !reading.isEmpty {
            return STTVocabTerm(content: surface, soundsLike: [reading])
        }
        return STTVocabTerm(content: surface, soundsLike: [])
    }
}
