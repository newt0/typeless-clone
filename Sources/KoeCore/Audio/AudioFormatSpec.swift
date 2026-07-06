import Foundation

/// The one PCM format Koe streams to every STT provider: 16kHz, mono,
/// little-endian signed 16-bit, interleaved (Design §7.4). No client-side
/// NR/AGC — the raw converted audio is sent (invariant 8: normalization is the
/// LLM's job, not the pipeline's).
///
/// The App-layer `AVAudioConverter` is configured from this value; keeping the
/// wire numbers here (rather than inline in the AVFoundation glue) lets tests
/// assert the format and lets the session-buffer cap math stay pure.
public struct AudioFormatSpec: Sendable, Equatable {
    /// Samples per second (16000 for STT).
    public let sampleRate: Double
    /// Channel count (1 = mono).
    public let channelCount: Int
    /// Bytes in one sample of one channel (2 = Int16).
    public let bytesPerSample: Int

    public init(sampleRate: Double, channelCount: Int, bytesPerSample: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bytesPerSample = bytesPerSample
    }

    /// 16kHz mono PCM16 LE — the format all STT adapters consume.
    public static let stt = AudioFormatSpec(sampleRate: 16_000, channelCount: 1, bytesPerSample: 2)

    /// Bytes in one sample frame across all channels.
    public var bytesPerFrame: Int { channelCount * bytesPerSample }

    /// Bytes of audio produced per wall-clock second at this format.
    public var bytesPerSecond: Int { Int(sampleRate.rounded()) * bytesPerFrame }

    /// Frame count for a chunk of `duration` at a given capture sample rate.
    /// Used to size the input tap so converted chunks land in the 20–50ms
    /// window STT expects. The tap's sample rate is the device's, not
    /// necessarily 16kHz, so the rate is passed in. Never returns < 1.
    public func frameCount(for duration: Duration, atSampleRate rate: Double) -> Int {
        max(1, Int((rate * duration.koeSeconds).rounded()))
    }

    /// Byte budget for `duration` of audio at this format — the session-buffer
    /// cap is `byteBudget(for: maxSessionRecording)`. Never negative.
    public func byteBudget(for duration: Duration) -> Int {
        max(0, Int((Double(bytesPerSecond) * duration.koeSeconds).rounded()))
    }
}

extension Duration {
    /// This duration as fractional seconds. Named to avoid colliding with any
    /// future stdlib member; internal to the audio math.
    var koeSeconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
