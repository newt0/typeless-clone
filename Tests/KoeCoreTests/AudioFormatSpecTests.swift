import Testing
import Foundation
@testable import KoeCore

@Suite("AudioFormatSpec")
struct AudioFormatSpecTests {
    @Test("STT format is 16kHz mono PCM16 (invariant: the one wire format)")
    func sttFormat() {
        let f = AudioFormatSpec.stt
        #expect(f.sampleRate == 16_000)
        #expect(f.channelCount == 1)
        #expect(f.bytesPerSample == 2)
        #expect(f.bytesPerFrame == 2)
        #expect(f.bytesPerSecond == 32_000)
    }

    @Test("byteBudget matches the ~38MB / 20-minute session cap")
    func sessionCapByteBudget() {
        // 20 min × 16000 × 2 = 38,400,000 bytes ≈ 38MB (Design §7.4).
        let cap = AudioFormatSpec.stt.byteBudget(for: .seconds(20 * 60))
        #expect(cap == 38_400_000)
    }

    @Test("byteBudget is proportional and non-negative")
    func byteBudgetProportional() {
        let f = AudioFormatSpec.stt
        #expect(f.byteBudget(for: .seconds(1)) == 32_000)
        #expect(f.byteBudget(for: .milliseconds(500)) == 16_000)
        #expect(f.byteBudget(for: .zero) == 0)
    }

    @Test("frameCount sizes the input tap for the 40ms chunk window")
    func frameCountForChunk() {
        let f = AudioFormatSpec.stt
        // 40ms at the device's 48kHz tap → 1920 frames.
        #expect(f.frameCount(for: .milliseconds(40), atSampleRate: 48_000) == 1_920)
        // 40ms at 16kHz → 640 frames.
        #expect(f.frameCount(for: .milliseconds(40), atSampleRate: 16_000) == 640)
    }

    @Test("frameCount never returns less than one frame")
    func frameCountFloor() {
        #expect(AudioFormatSpec.stt.frameCount(for: .zero, atSampleRate: 48_000) == 1)
    }
}
