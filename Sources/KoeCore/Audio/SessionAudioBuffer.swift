import Foundation

/// In-memory accumulator for one recording session's PCM16 audio, retained so
/// STT can batch-resend the whole utterance on a timeout (Design §7.4;
/// invariant 1 — zero text loss). Capped at
/// ``KoeConstants/maxSessionRecording`` (~20 min ≈ 38MB at 16kHz mono PCM16);
/// once full, recording stops with a HUD notice rather than growing unbounded.
///
/// Pure value type: the App-layer capture engine owns one and appends converted
/// chunks off the audio thread, so cap enforcement is unit-tested without a
/// live `AVAudioEngine`.
public struct SessionAudioBuffer: Sendable {
    /// What the caller should do after an ``append(_:)``.
    public enum AppendOutcome: Sendable, Equatable {
        /// Chunk stored in full; keep recording.
        case accepted
        /// The cap was reached; the chunk was stored up to the cap (any
        /// overflow dropped). Stop recording and show the HUD notice.
        case capReached
    }

    public let format: AudioFormatSpec
    /// Hard ceiling in bytes; ``data`` never exceeds this.
    public let capBytes: Int
    /// The accumulated little-endian PCM16 audio, in arrival order.
    public private(set) var data: Data

    public init(
        format: AudioFormatSpec = .stt,
        cap: Duration = KoeConstants.maxSessionRecording
    ) {
        self.format = format
        self.capBytes = format.byteBudget(for: cap)
        self.data = Data()
        // Avoid re-allocating on every chunk during a long session, but don't
        // eagerly reserve the full ~38MB for a session that stays short.
        self.data.reserveCapacity(min(capBytes, 1 << 20))
    }

    /// Append a converted PCM16 chunk, truncating whatever crosses the cap so
    /// ``data`` never exceeds ``capBytes``.
    @discardableResult
    public mutating func append(_ chunk: Data) -> AppendOutcome {
        let remaining = capBytes - data.count
        guard remaining > 0 else { return .capReached }
        if chunk.count < remaining {
            data.append(chunk)
            return .accepted
        }
        // This chunk reaches or overflows the cap: keep the head, drop the rest.
        data.append(chunk.prefix(remaining))
        return .capReached
    }

    /// Wall-clock duration currently buffered (bytes ÷ bytes-per-second).
    public var duration: Duration {
        guard format.bytesPerSecond > 0 else { return .zero }
        return .seconds(Double(data.count) / Double(format.bytesPerSecond))
    }

    /// Drop all buffered audio to begin a new session, keeping the allocation.
    public mutating func reset() {
        data.removeAll(keepingCapacity: true)
    }
}
