import Testing
import Foundation
@testable import KoeStorage
import KoeCore

private func makeStore() throws -> DictionaryStore {
    try DictionaryStore.inMemory(now: { Date(timeIntervalSince1970: 1_000_000) })
}

@Suite("DictionaryTerm serializers")
struct DictionaryTermTests {
    private func term(_ surface: String, _ reading: String? = nil, _ notes: String? = nil) -> DictionaryTerm {
        DictionaryTerm(surface: surface, reading: reading, notes: notes, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test("prompt entry mirrors surface/reading/notes")
    func promptEntry() {
        let e = term("Claude Code", "くろーどこーど", "AIツール").promptEntry
        #expect(e == DictionaryEntry(surface: "Claude Code", reading: "くろーどこーど", note: "AIツール"))
    }

    @Test("STT vocab uses reading as a sounds-like hint")
    func sttVocabWithReading() {
        #expect(term("Speechmatics", "すぴーちまてぃっくす").sttVocabTerm
                == STTVocabTerm(content: "Speechmatics", soundsLike: ["すぴーちまてぃっくす"]))
    }

    @Test("STT vocab omits sounds-like when reading is missing or empty")
    func sttVocabWithoutReading() {
        #expect(term("Koe").sttVocabTerm == STTVocabTerm(content: "Koe", soundsLike: []))
        #expect(term("Koe", "").sttVocabTerm == STTVocabTerm(content: "Koe", soundsLike: []))
    }
}

@Suite("DictionaryStore")
struct DictionaryStoreTests {

    @Test("add then list")
    func addAndList() async throws {
        let store = try makeStore()
        try await store.add(surface: "Claude Code", reading: "くろーどこーど")
        try await store.add(surface: "Koe")
        let all = try await store.all()
        #expect(all.map(\.surface) == ["Claude Code", "Koe"]) // ordered by surface
    }

    @Test("duplicate surface is rejected")
    func duplicateRejected() async throws {
        let store = try makeStore()
        try await store.add(surface: "Koe")
        await #expect(throws: (any Error).self) {
            try await store.add(surface: "Koe")
        }
    }

    @Test("update changes reading/notes")
    func updateTerm() async throws {
        let store = try makeStore()
        var term = try await store.add(surface: "Cursor", reading: "かーそる")
        term.reading = "カーソル"
        term.notes = "エディタ"
        try await store.update(term)
        let fetched = try #require(try await store.all().first)
        #expect(fetched.reading == "カーソル")
        #expect(fetched.notes == "エディタ")
    }

    @Test("delete removes a term")
    func deleteTerm() async throws {
        let store = try makeStore()
        let term = try await store.add(surface: "Deepgram")
        try await store.delete(id: try #require(term.id))
        #expect(try await store.all().isEmpty)
    }

    @Test("feeds the LLM prompt: assembled prompt contains dictionary terms")
    func feedsPrompt() async throws {
        let store = try makeStore()
        try await store.add(surface: "Claude Code", reading: "くろーどこーど")
        let assembler = PromptAssembler()
        let prompt = assembler.assemble(transcript: "テスト", dictionary: try await store.promptEntries())
        #expect(prompt.system.contains("Claude Code（読み: くろーどこーど）"))
    }

    @Test("feeds STT vocabulary")
    func feedsSTT() async throws {
        let store = try makeStore()
        try await store.add(surface: "Soniox", reading: "そにおっくす")
        try await store.add(surface: "Gemini")
        let vocab = try await store.sttVocabulary()
        #expect(vocab.contains(STTVocabTerm(content: "Soniox", soundsLike: ["そにおっくす"])))
        #expect(vocab.contains(STTVocabTerm(content: "Gemini", soundsLike: [])))
    }
}
