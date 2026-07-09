import Testing
import Foundation
@testable import KoeCore

// MARK: - Fakes

/// Streaming leg: succeeds echoing chunks, or consumes `failAfterChunks` then
/// throws `error` (models a socket dying mid-utterance).
private struct FakeStreaming: Transcribing {
    enum Behavior: Sendable {
        case succeed
        case failAfterChunks(Int, error: STTError)
    }
    let behavior: Behavior

    func transcribe(
        _ audio: AsyncThrowingStream<Data, any Error>,
        _ context: UtteranceContext,
        onRecordingEnded: @escaping @Sendable () async -> Void
    ) async throws -> String {
        switch behavior {
        case .succeed:
            var collected = Data()
            for try await chunk in audio { collected.append(chunk) }
            await onRecordingEnded()
            return String(decoding: collected, as: UTF8.self)
        case .failAfterChunks(let count, let error):
            var seen = 0
            for try await _ in audio {
                seen += 1
                if seen >= count { break }
            }
            await onRecordingEnded()
            throw error
        }
    }
}

private actor FakeBatch: BatchTranscribing {
    enum Behavior { case reply(String), fail }
    private let behavior: Behavior
    private(set) var receivedWAVs: [Data] = []
    init(_ behavior: Behavior) { self.behavior = behavior }
    func transcribe(wav: Data, vocab: [STTVocabTerm]) async throws -> String {
        receivedWAVs.append(wav)
        switch behavior {
        case .reply(let text): return text
        case .fail: throw STTError.server(type: "job_rejected")
        }
    }
}

private actor MemoryAudioStore: UntranscribedAudioStoring {
    private(set) var saved: [String: Data] = [:]
    private(set) var deleted: [String] = []
    var failSave = false
    func setFailSave() { failSave = true }
    func save(wav: Data) async -> String? {
        if failSave { return nil }
        let id = "audio-\(saved.count)"
        saved[id] = wav
        return id
    }
    func load(id: String) async -> Data? { saved[id] }
    func delete(id: String) async { deleted.append(id); saved[id] = nil }
}

private func audioStream(_ chunks: [String], fault: Bool = false) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
        if fault {
            continuation.finish(throwing: AudioCaptureFault())
        } else {
            continuation.finish()
        }
    }
}

private struct AudioCaptureFault: Error {}

private let ctx = UtteranceContext(index: 0)

// MARK: - Tests

@Suite("ResilientTranscriber")
struct ResilientTranscriberTests {

    @Test("streaming success never touches the batch leg")
    func streamingSuccess() async throws {
        let batch = FakeBatch(.reply("unused"))
        let t = ResilientTranscriber(
            streaming: FakeStreaming(behavior: .succeed),
            batch: batch, store: MemoryAudioStore()
        )
        let transcript = try await t.transcribe(audioStream(["こん", "にちは"]), ctx) {}
        #expect(transcript == "こんにちは")
        #expect(await batch.receivedWAVs.isEmpty)
    }

    @Test("a dead socket mid-utterance resends the FULL capture, including audio after the failure")
    func resendCoversPostFailureAudio() async throws {
        // Streaming dies after 1 chunk; the mic keeps producing 2 more. The
        // batch WAV must contain all 3 (zero text loss across the ladder).
        let batch = FakeBatch(.reply("全部聞こえました"))
        let t = ResilientTranscriber(
            streaming: FakeStreaming(behavior: .failAfterChunks(1, error: .connection)),
            batch: batch, store: MemoryAudioStore()
        )
        let transcript = try await t.transcribe(audioStream(["あ", "い", "う"]), ctx) {}
        #expect(transcript == "全部聞こえました")
        let wavs = await batch.receivedWAVs
        #expect(wavs.count == 1)
        let pcm = wavs[0].dropFirst(44) // strip the RIFF header
        #expect(String(decoding: pcm, as: UTF8.self) == "あいう")
    }

    @Test("double fault persists the WAV and throws a retryable UnrecoveredUtterance")
    func doubleFaultPersists() async {
        let store = MemoryAudioStore()
        let t = ResilientTranscriber(
            streaming: FakeStreaming(behavior: .failAfterChunks(1, error: .timeout)),
            batch: FakeBatch(.fail), store: store
        )
        do {
            _ = try await t.transcribe(audioStream(["あ"]), ctx) {}
            Issue.record("expected UnrecoveredUtterance")
        } catch let error as UnrecoveredUtterance {
            #expect(error.audioID != nil)
            if let id = error.audioID {
                #expect(await store.saved[id] != nil)
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("double fault with a failed save surfaces audioID == nil (not retryable)")
    func doubleFaultSaveFailed() async {
        let store = MemoryAudioStore()
        await store.setFailSave()
        let t = ResilientTranscriber(
            streaming: FakeStreaming(behavior: .failAfterChunks(1, error: .connection)),
            batch: FakeBatch(.fail), store: store
        )
        do {
            _ = try await t.transcribe(audioStream(["あ"]), ctx) {}
            Issue.record("expected UnrecoveredUtterance")
        } catch let error as UnrecoveredUtterance {
            #expect(error.audioID == nil)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("a mic fault is NOT resent — incomplete audio fails loudly with the original error")
    func micFaultNotResent() async {
        let batch = FakeBatch(.reply("unused"))
        let t = ResilientTranscriber(
            streaming: FakeStreaming(behavior: .failAfterChunks(1, error: .connection)),
            batch: batch, store: MemoryAudioStore()
        )
        await #expect(throws: STTError.connection) {
            _ = try await t.transcribe(audioStream(["あ"], fault: true), ctx) {}
        }
        #expect(await batch.receivedWAVs.isEmpty)
    }

    @Test("retry success keeps the WAV until discardRecovered (post-pipeline deletion)")
    func retrySuccess() async throws {
        let store = MemoryAudioStore()
        let id = await store.save(wav: Data("wav-bytes".utf8))!
        let t = ResilientTranscriber(
            streaming: FakeStreaming(behavior: .succeed),
            batch: FakeBatch(.reply("再試行成功")), store: store
        )
        let transcript = try await t.retryTranscribe(audioID: id)
        #expect(transcript == "再試行成功")
        // Not deleted yet — a downstream format/insert failure must keep the
        // handle retryable (review finding). The coordinator discards after
        // the whole pipeline completes:
        #expect(await store.deleted.isEmpty)
        await t.discardRecovered(audioID: id)
        #expect(await store.deleted == [id])
    }

    @Test("retry failure keeps the audio and stays retryable with the same id")
    func retryFailureKeepsAudio() async {
        let store = MemoryAudioStore()
        let id = await store.save(wav: Data("wav-bytes".utf8))!
        let t = ResilientTranscriber(
            streaming: FakeStreaming(behavior: .succeed),
            batch: FakeBatch(.fail), store: store
        )
        do {
            _ = try await t.retryTranscribe(audioID: id)
            Issue.record("expected UnrecoveredUtterance")
        } catch let error as UnrecoveredUtterance {
            #expect(error.audioID == id)
            #expect(await store.saved[id] != nil)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

@Suite("WAVEncoder")
struct WAVEncoderTests {
    @Test("canonical 44-byte header with correct sizes for the STT format")
    func header() {
        let pcm = Data(repeating: 0x42, count: 3200) // 100ms @ 16kHz mono 16-bit
        let wav = WAVEncoder.wav(pcm16: pcm)
        #expect(wav.count == 44 + pcm.count)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav.subdata(in: 8..<12), as: UTF8.self) == "WAVE")
        func le32(_ offset: Int) -> UInt32 {
            wav.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        func le16(_ offset: Int) -> UInt16 {
            wav.subdata(in: offset..<offset + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        }
        #expect(le32(4) == UInt32(36 + pcm.count))   // RIFF chunk size
        #expect(le16(22) == 1)                        // mono
        #expect(le32(24) == 16_000)                   // sample rate
        #expect(le32(28) == 32_000)                   // byte rate
        #expect(le16(34) == 16)                       // bits per sample
        #expect(le32(40) == UInt32(pcm.count))        // data size
    }
}
