import Testing
import Foundation
@testable import KoeCore

@Suite("SessionAudioBuffer")
struct SessionAudioBufferTests {
    /// A tiny cap keeps the fixtures small: 100ms at 16kHz mono PCM16 = 3200B.
    private func smallBuffer() -> SessionAudioBuffer {
        SessionAudioBuffer(cap: .milliseconds(100))
    }

    @Test("appends accumulate in order under the cap")
    func accumulates() {
        var buf = smallBuffer()
        #expect(buf.append(Data([1, 2, 3, 4])) == .accepted)
        #expect(buf.append(Data([5, 6])) == .accepted)
        #expect(Array(buf.data) == [1, 2, 3, 4, 5, 6])
    }

    @Test("cap byte budget derives from the format")
    func capBytes() {
        #expect(smallBuffer().capBytes == 3_200) // 0.1s × 32000 B/s
    }

    @Test("a chunk crossing the cap is truncated and signals capReached")
    func truncatesAtCap() {
        var buf = SessionAudioBuffer(cap: .milliseconds(100)) // 3200B cap
        #expect(buf.append(Data(repeating: 0xAA, count: 3_000)) == .accepted)
        // 400B would overflow the remaining 200B: keep 200, drop 200.
        #expect(buf.append(Data(repeating: 0xBB, count: 400)) == .capReached)
        #expect(buf.data.count == 3_200)
    }

    @Test("appends after the cap are rejected without growth")
    func rejectsPastCap() {
        var buf = SessionAudioBuffer(cap: .milliseconds(100))
        _ = buf.append(Data(repeating: 0, count: 3_200)) // fills exactly → capReached
        #expect(buf.append(Data([9, 9, 9])) == .capReached)
        #expect(buf.data.count == 3_200)
    }

    @Test("filling exactly to the cap reports capReached")
    func exactFill() {
        var buf = SessionAudioBuffer(cap: .milliseconds(100))
        #expect(buf.append(Data(repeating: 0, count: 3_200)) == .capReached)
        #expect(buf.data.count == 3_200)
    }

    @Test("duration reflects the buffered byte count")
    func durationTracksBytes() {
        var buf = smallBuffer()
        buf.append(Data(repeating: 0, count: 16_00)) // 1600B ÷ 32000 B/s = 50ms
        #expect(buf.duration == .milliseconds(50))
    }

    @Test("reset clears the buffer for a new session")
    func resetClears() {
        var buf = smallBuffer()
        buf.append(Data([1, 2, 3]))
        buf.reset()
        #expect(buf.data.isEmpty)
        #expect(buf.append(Data([4])) == .accepted)
    }
}
