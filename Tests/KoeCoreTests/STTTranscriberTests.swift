import Testing
import Foundation
@testable import KoeCore

/// Scripted STTClient: records the call sequence and, on `endUtterance`,
/// plays a scripted event tail (or stays silent to model a dead socket).
private actor ScriptedSTTClient: STTClient {
    enum Tail {
        case events([STTEvent], finish: Bool)
        case silent
    }
    private let tail: Tail
    private var continuation: AsyncStream<STTEvent>.Continuation?
    private(set) var log: [String] = []
    private(set) var receivedVocab: [STTVocabTerm] = []

    init(tail: Tail) { self.tail = tail }

    func prewarm() async throws {}

    func beginUtterance(vocab: [STTVocabTerm]) async throws -> AsyncStream<STTEvent> {
        receivedVocab = vocab
        let (stream, continuation) = AsyncStream<STTEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    func send(audioChunk: Data) async throws {
        log.append("send:\(String(decoding: audioChunk, as: UTF8.self))")
    }

    func endUtterance() async throws {
        log.append("end")
        switch tail {
        case .events(let events, let finish):
            for event in events { continuation?.yield(event) }
            if finish { continuation?.finish() }
        case .silent:
            break
        }
    }

    func mark(_ entry: String) { log.append(entry) }
}

private func audioStream(_ chunks: [String]) -> AsyncStream<Data> {
    AsyncStream { continuation in
        for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
        continuation.finish()
    }
}

private let ctx = UtteranceContext(index: 0)

@Suite("STTTranscriber")
struct STTTranscriberTests {

    @Test("chunks stream in order, finals concatenate, partials are ignored")
    func happyPath() async throws {
        let client = ScriptedSTTClient(tail: .events(
            [.partial("こんに"), .final("こんにちは"), .partial("せか"), .final("世界")],
            finish: true
        ))
        let transcriber = STTTranscriber(client: client, vocab: {
            [STTVocabTerm(content: "世界", soundsLike: ["せかい"])]
        })
        let transcript = try await transcriber.transcribe(audioStream(["a", "b"]), ctx) {
            await client.mark("recordingEnded")
        }
        #expect(transcript == "こんにちは世界")
        // onRecordingEnded fires after the last chunk and before endUtterance,
        // so the session leaves `recording` at true end-of-speech.
        #expect(await client.log == ["send:a", "send:b", "recordingEnded", "end"])
        #expect(await client.receivedVocab == [STTVocabTerm(content: "世界", soundsLike: ["せかい"])])
    }

    @Test("a provider error event propagates as the thrown STTError")
    func errorPropagates() async {
        let client = ScriptedSTTClient(tail: .events(
            [.final("途中まで"), .error(.server(type: "quota_exceeded"))],
            finish: true
        ))
        let transcriber = STTTranscriber(client: client)
        await #expect(throws: STTError.server(type: "quota_exceeded")) {
            _ = try await transcriber.transcribe(audioStream(["a"]), ctx) {}
        }
    }

    @Test("a dead socket after end-of-speech throws timeout instead of hanging the FIFO")
    func stalledFinalsTimeOut() async {
        let client = ScriptedSTTClient(tail: .silent)
        let transcriber = STTTranscriber(client: client, tailTimeout: .milliseconds(50))
        await #expect(throws: STTError.timeout) {
            _ = try await transcriber.transcribe(audioStream(["a"]), ctx) {}
        }
    }

    @Test("cancellation mid-recording throws rather than returning a truncated transcript")
    func cancellationAborts() async {
        let client = ScriptedSTTClient(tail: .silent)
        let transcriber = STTTranscriber(client: client, tailTimeout: .seconds(30))
        // A mic stream that never finishes: the user is still holding the key.
        let audio = AsyncStream<Data> { _ in }
        let task = Task { try await transcriber.transcribe(audio, ctx) {} }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        switch await task.result {
        case .success:
            Issue.record("expected cancellation to throw, got a transcript")
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }
}
