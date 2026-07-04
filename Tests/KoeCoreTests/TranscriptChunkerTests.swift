import Testing
@testable import KoeCore

@Suite("TranscriptChunker")
struct TranscriptChunkerTests {

    @Test("short transcripts are not split")
    func belowThreshold() {
        let text = String(repeating: "あ", count: 100)
        #expect(TranscriptChunker.chunk(text) == [text])
    }

    @Test("exactly at threshold is not split")
    func atThreshold() {
        let text = String(repeating: "あ", count: KoeConstants.longFormChunkThreshold)
        #expect(TranscriptChunker.chunk(text).count == 1)
    }

    @Test("long transcript splits at sentence boundaries into <=target chunks")
    func splitsLongForm() {
        // 10 sentences of ~120 chars each ≈ 1200 chars, well over threshold.
        let sentence = String(repeating: "本", count: 118) + "。"
        let text = String(repeating: sentence, count: 10)
        let chunks = TranscriptChunker.chunk(text)
        #expect(chunks.count > 1)
        // Each packed chunk stays within target (single sentences are < target).
        for c in chunks { #expect(c.count <= KoeConstants.longFormChunkTarget) }
        // Every chunk ends on a sentence terminator (no mid-sentence cut).
        for c in chunks { #expect(c.hasSuffix("。")) }
    }

    @Test("chunks join back to the original text")
    func roundTrips() {
        let text = String(repeating: "これはテストです。次の文もあります！さらに疑問文？", count: 20)
        let chunks = TranscriptChunker.chunk(text)
        #expect(TranscriptChunker.join(chunks) == text)
    }

    @Test("a single sentence longer than target is not cut mid-sentence")
    func oversizedSentenceKeptWhole() {
        let huge = String(repeating: "長", count: KoeConstants.longFormChunkTarget + 200) + "。"
        let tail = "短い。"
        let chunks = TranscriptChunker.chunk(huge + tail)
        #expect(chunks.contains(huge))          // kept intact, oversized
        #expect(TranscriptChunker.join(chunks) == huge + tail)
    }

    @Test("long boundary-less text stays a single chunk")
    func noBoundaries() {
        let text = String(repeating: "あ", count: KoeConstants.longFormChunkThreshold + 300)
        #expect(TranscriptChunker.chunk(text) == [text])
    }
}
