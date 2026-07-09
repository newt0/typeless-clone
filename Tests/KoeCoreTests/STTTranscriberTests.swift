import Testing
import Foundation
@testable import KoeCore

/// Scripted STTClient: records the call sequence and plays a scripted event
/// tail on `endUtterance` (or on the first `send`, to model a server that
/// finalizes early; or stays silent to model a dead socket).
private actor ScriptedSTTClient: STTClient {
    enum Tail {
        case events([STTEvent], finish: Bool)
        case eventsOnFirstSend([STTEvent], finish: Bool)
        case silent
    }
    private let tail: Tail
    private let failSend: Bool
    private var sent = false
    private var continuation: AsyncStream<STTEvent>.Continuation?
    private(set) var log: [String] = []
    private(set) var receivedVocab: [STTVocabTerm] = []

    init(tail: Tail, failSend: Bool = false) {
        self.tail = tail
        self.failSend = failSend
    }

    func prewarm() async throws {}

    func beginUtterance(vocab: [STTVocabTerm]) async throws -> AsyncStream<STTEvent> {
        receivedVocab = vocab
        let (stream, continuation) = AsyncStream<STTEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    func send(audioChunk: Data) async throws {
        if failSend { throw STTError.connection }
        log.append("send:\(String(decoding: audioChunk, as: UTF8.self))")
        if case .eventsOnFirstSend(let events, let finish) = tail, !sent {
            sent = true
            for event in events { continuation?.yield(event) }
            if finish { continuation?.finish() }
        }
    }

    func endUtterance() async throws {
        log.append("end")
        if case .events(let events, let finish) = tail {
            for event in events { continuation?.yield(event) }
            if finish { continuation?.finish() }
        }
    }

    func mark(_ entry: String) { log.append(entry) }
}

private func audioStream(_ chunks: [String]) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
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
        let audio = AsyncThrowingStream<Data, any Error> { _ in }
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

    @Test("a server that finalizes before key-up still fires onRecordingEnded and keeps the transcript")
    func earlyServerCloseStillEndsRecording() async throws {
        // Review finding: the .transcript step can win the race before the
        // feeder reaches onRecordingEnded — the session would stay `recording`
        // and the coordinator would drop a fully-transcribed utterance.
        let client = ScriptedSTTClient(tail: .eventsOnFirstSend([.final("早い確定")], finish: true))
        let transcriber = STTTranscriber(client: client)
        // One chunk, then the stream stays open: the user is still holding the key.
        let audio = AsyncThrowingStream<Data, any Error> { continuation in
            continuation.yield(Data("a".utf8))
        }
        let transcript = try await transcriber.transcribe(audio, ctx) {
            await client.mark("recordingEnded")
        }
        #expect(transcript == "早い確定")
        #expect(await client.log.filter { $0 == "recordingEnded" }.count == 1)
    }

    @Test("a mid-recording send failure throws but still fires onRecordingEnded exactly once")
    func sendFailureStillEndsRecording() async {
        let client = ScriptedSTTClient(tail: .silent, failSend: true)
        let transcriber = STTTranscriber(client: client)
        await #expect(throws: STTError.connection) {
            _ = try await transcriber.transcribe(audioStream(["a"]), ctx) {
                await client.mark("recordingEnded")
            }
        }
        #expect(await client.log.filter { $0 == "recordingEnded" }.count == 1)
    }

    @Test("a mic-capture fault mid-stream fails loudly instead of transcribing a truncated utterance")
    func audioFaultPropagates() async {
        struct MicDied: Error {}
        let client = ScriptedSTTClient(tail: .silent)
        let transcriber = STTTranscriber(client: client)
        let audio = AsyncThrowingStream<Data, any Error> { continuation in
            continuation.yield(Data("a".utf8))
            continuation.finish(throwing: MicDied())
        }
        await #expect(throws: MicDied.self) {
            _ = try await transcriber.transcribe(audio, ctx) {
                await client.mark("recordingEnded")
            }
        }
        #expect(await client.log.filter { $0 == "recordingEnded" }.count == 1)
    }
}
