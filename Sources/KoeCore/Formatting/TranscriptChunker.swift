import Foundation

/// Splits long transcripts for parallel formatting (Design §5.1; plan M6-T3).
///
/// Standard utterances (≤ threshold) are never split. Longer ones are split
/// greedily at sentence boundaries into ~`target`-sized chunks, formatted in
/// parallel, then joined for a single insertion. Splitting never cuts inside a
/// sentence, so a lone sentence longer than `target` becomes one oversized
/// chunk rather than being broken mid-way.
public enum TranscriptChunker {
    /// Sentence terminators used as split points.
    private static let terminators: Set<Character> = ["。", "！", "？", "!", "?", "．", "\n"]

    public static func chunk(
        _ transcript: String,
        threshold: Int = KoeConstants.longFormChunkThreshold,
        target: Int = KoeConstants.longFormChunkTarget
    ) -> [String] {
        guard transcript.count > threshold else { return [transcript] }

        var chunks: [String] = []
        var current = ""
        for sentence in splitSentences(transcript) {
            if current.isEmpty {
                current = sentence
            } else if current.count + sentence.count <= target {
                current += sentence
            } else {
                chunks.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Reassemble formatted chunks. Because chunks keep their boundary
    /// punctuation, plain concatenation restores the text.
    public static func join(_ chunks: [String]) -> String {
        chunks.joined()
    }

    /// Split into sentences, keeping each terminator attached to its sentence.
    /// Trailing text with no terminator becomes a final sentence.
    private static func splitSentences(_ text: String) -> [String] {
        var result: [String] = []
        var buffer = ""
        for ch in text {
            buffer.append(ch)
            if terminators.contains(ch) {
                result.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty { result.append(buffer) }
        return result
    }
}
