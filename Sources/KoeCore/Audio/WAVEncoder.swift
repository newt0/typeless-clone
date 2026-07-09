import Foundation

/// Wraps raw PCM16 audio in a minimal RIFF/WAVE header (plan M4-T3): the
/// batch-resend endpoint takes a file upload, and the session buffer holds
/// headerless wire-format PCM (``AudioFormatSpec``).
public enum WAVEncoder {
    /// Little-endian 44-byte canonical PCM WAV header + data.
    public static func wav(pcm16 data: Data, format: AudioFormatSpec = .stt) -> Data {
        let sampleRate = UInt32(format.sampleRate)
        let channels = UInt16(format.channelCount)
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(clamping: data.count)

        var header = Data(capacity: 44)
        header.append(contentsOf: Array("RIFF".utf8))
        header.appendLE(UInt32(36) &+ dataSize)      // chunk size
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.appendLE(UInt32(16))                  // fmt chunk size
        header.appendLE(UInt16(1))                   // PCM
        header.appendLE(channels)
        header.appendLE(sampleRate)
        header.appendLE(byteRate)
        header.appendLE(blockAlign)
        header.appendLE(bitsPerSample)
        header.append(contentsOf: Array("data".utf8))
        header.appendLE(dataSize)
        return header + data
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
