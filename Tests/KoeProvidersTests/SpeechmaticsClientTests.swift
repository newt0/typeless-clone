import Testing
import Foundation
@testable import KoeProviders
import KoeCore

// MARK: - Test double

/// Scripts inbound server frames and records outbound frames. An actor so state
/// stays race-free; `receive` has a single consumer (the adapter's receive loop).
private actor FakeWebSocketChannel: WebSocketChannel {
    private var incoming: [WSMessage]
    private var sentText: [String] = []
    private var sentBinary: [Data] = []
    /// When true, `send(text:)` throws — emulates writing to a dead/idle-closed
    /// socket (a raw transport error the adapter must normalize/self-heal).
    private let failTextSend: Bool
    /// When true, `send(binary:)` throws — emulates a mid-utterance socket drop.
    private let failBinarySend: Bool

    init(script: [WSMessage], failTextSend: Bool = false, failBinarySend: Bool = false) {
        incoming = script
        self.failTextSend = failTextSend
        self.failBinarySend = failBinarySend
    }

    func send(text: String) async throws {
        if failTextSend { throw URLError(.networkConnectionLost) }
        sentText.append(text)
    }
    func send(binary: Data) async throws {
        if failBinarySend { throw URLError(.networkConnectionLost) }
        sentBinary.append(binary)
    }

    func receive() async throws -> WSMessage {
        // Emulate a live socket: block awaiting more frames once the script is
        // drained (scripts that terminate the stream end with EndOfTranscript/
        // Error, so the receive loop returns before reaching this).
        if incoming.isEmpty {
            try? await Task.sleep(for: .seconds(3600))
            throw STTError.connection
        }
        return incoming.removeFirst()
    }

    func close() async {}

    func recordedText() -> [String] { sentText }
    func recordedBinary() -> [Data] { sentBinary }
}

/// Build a scripted server message frame.
private func serverMsg(_ message: String, transcript: String? = nil, type: String? = nil) -> WSMessage {
    var obj: [String: Any] = ["message": message]
    if let transcript { obj["metadata"] = ["transcript": transcript] }
    if let type { obj["type"] = type }
    let data = try! JSONSerialization.data(withJSONObject: obj)
    return .text(String(data: data, encoding: .utf8)!)
}

private func client(_ fake: FakeWebSocketChannel) -> SpeechmaticsClient {
    SpeechmaticsClient(apiKey: "test-key", connect: { _, _ in fake })
}

private actor Counter {
    private(set) var count = 0
    func bump() { count += 1 }
    func bumpAndGet() -> Int { count += 1; return count }
}

/// A one-shot gate: `wait()` suspends until `openGate()` is called.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func openGate() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

// MARK: - Deterministic unit tests (no network)

@Suite("SpeechmaticsClient wire protocol")
struct SpeechmaticsClientWireTests {

    @Test("StartRecognition declares 16kHz PCM16 mono, ja/enhanced, partials on")
    func startRecognitionConfig() async throws {
        let fake = FakeWebSocketChannel(script: [serverMsg("EndOfTranscript")])
        let c = client(fake)
        try await c.prewarm()
        _ = try await c.beginUtterance(vocab: [])

        let start = await fake.recordedText().first
        let obj = try JSONSerialization.jsonObject(with: Data((start ?? "").utf8)) as! [String: Any]
        #expect(obj["message"] as? String == "StartRecognition")

        let audio = obj["audio_format"] as! [String: Any]
        #expect(audio["type"] as? String == "raw")
        #expect(audio["encoding"] as? String == "pcm_s16le")
        #expect(audio["sample_rate"] as? Int == 16000)

        let tc = obj["transcription_config"] as! [String: Any]
        #expect(tc["language"] as? String == "ja")
        #expect(tc["operating_point"] as? String == "enhanced")
        #expect(tc["enable_partials"] as? Bool == true)
    }

    @Test("no smart-formatting / ITN / entity options are sent (invariant 8)")
    func noSmartFormatting() async throws {
        let fake = FakeWebSocketChannel(script: [serverMsg("EndOfTranscript")])
        let c = client(fake)
        try await c.prewarm()
        _ = try await c.beginUtterance(vocab: [])

        let obj = try JSONSerialization.jsonObject(with: Data((await fake.recordedText().first ?? "").utf8)) as! [String: Any]
        let tc = obj["transcription_config"] as! [String: Any]
        #expect(tc["enable_entities"] == nil)
        #expect(tc["punctuation_overrides"] == nil)
        #expect(tc["output_locale"] == nil)
    }

    @Test("endUtterance sends EndOfStream with last_seq_no = chunks sent")
    func endOfStreamSeqNo() async throws {
        // Empty script → the receive loop blocks, keeping the session live while
        // we exercise send/endUtterance framing.
        let fake = FakeWebSocketChannel(script: [])
        let c = client(fake)
        try await c.prewarm()
        _ = try await c.beginUtterance(vocab: [])
        try await c.send(audioChunk: Data([1, 2]))
        try await c.send(audioChunk: Data([3, 4]))
        try await c.send(audioChunk: Data([5, 6]))
        try await c.endUtterance()

        #expect(await fake.recordedBinary().count == 3)
        let end = try JSONSerialization.jsonObject(with: Data((await fake.recordedText().last ?? "").utf8)) as! [String: Any]
        #expect(end["message"] as? String == "EndOfStream")
        #expect(end["last_seq_no"] as? Int == 3)
    }

    @Test("send before beginUtterance throws notStarted")
    func sendBeforeStart() async {
        let c = client(FakeWebSocketChannel(script: []))
        await #expect(throws: STTError.notStarted) {
            try await c.send(audioChunk: Data([0]))
        }
    }

    @Test("send after prewarm but before beginUtterance throws notStarted")
    func sendAfterPrewarmOnly() async throws {
        let c = client(FakeWebSocketChannel(script: []))
        try await c.prewarm() // channel is live but no session started
        await #expect(throws: STTError.notStarted) { try await c.send(audioChunk: Data([0])) }
    }

    @Test("endUtterance after prewarm but before beginUtterance throws notStarted")
    func endAfterPrewarmOnly() async throws {
        let c = client(FakeWebSocketChannel(script: []))
        try await c.prewarm()
        await #expect(throws: STTError.notStarted) { try await c.endUtterance() }
    }

    @Test("send after endUtterance throws notStarted")
    func sendAfterEnd() async throws {
        let c = client(FakeWebSocketChannel(script: []))
        try await c.prewarm()
        _ = try await c.beginUtterance(vocab: [])
        try await c.endUtterance()
        await #expect(throws: STTError.notStarted) { try await c.send(audioChunk: Data([0])) }
    }

    @Test("endUtterance twice throws notStarted the second time")
    func doubleEnd() async throws {
        let c = client(FakeWebSocketChannel(script: []))
        try await c.prewarm()
        _ = try await c.beginUtterance(vocab: [])
        try await c.endUtterance()
        await #expect(throws: STTError.notStarted) { try await c.endUtterance() }
    }

    @Test("send normalizes a raw transport error to STTError")
    func sendNormalizesError() async throws {
        let c = client(FakeWebSocketChannel(script: [], failBinarySend: true))
        try await c.prewarm()
        _ = try await c.beginUtterance(vocab: [])
        await #expect(throws: STTError.connection) { try await c.send(audioChunk: Data([0])) }
    }
}

@Suite("SpeechmaticsClient event stream")
struct SpeechmaticsClientStreamTests {

    @Test("partials then a final, ending on EndOfTranscript")
    func partialsThenFinal() async throws {
        let script = [
            serverMsg("RecognitionStarted"),
            serverMsg("AddPartialTranscript", transcript: "こん"),
            serverMsg("AddPartialTranscript", transcript: "こんにち"),
            serverMsg("AddTranscript", transcript: "こんにちは。"),
            serverMsg("EndOfTranscript"),
        ]
        let c = client(FakeWebSocketChannel(script: script))
        try await c.prewarm()
        let stream = try await c.beginUtterance(vocab: [])

        var events: [STTEvent] = []
        for await e in stream { events.append(e) }
        #expect(events == [.partial("こん"), .partial("こんにち"), .final("こんにちは。")])
    }

    @Test("empty transcripts are not emitted")
    func skipsEmpty() async throws {
        let script = [
            serverMsg("AddPartialTranscript", transcript: ""),
            serverMsg("AddTranscript", transcript: "資料を送ります。"),
            serverMsg("EndOfTranscript"),
        ]
        let c = client(FakeWebSocketChannel(script: script))
        try await c.prewarm()
        let stream = try await c.beginUtterance(vocab: [])

        var events: [STTEvent] = []
        for await e in stream { events.append(e) }
        #expect(events == [.final("資料を送ります。")])
    }

    @Test("server Error maps to .error(.server) then finishes")
    func serverError() async throws {
        let script = [serverMsg("RecognitionStarted"), serverMsg("Error", type: "not_authorised")]
        let c = client(FakeWebSocketChannel(script: script))
        try await c.prewarm()
        let stream = try await c.beginUtterance(vocab: [])

        var events: [STTEvent] = []
        for await e in stream { events.append(e) }
        #expect(events == [.error(.server(type: "not_authorised"))])
    }
}

@Suite("SpeechmaticsClient connection lifecycle")
struct SpeechmaticsClientLifecycleTests {

    @Test("a dropped/errored session lets the next utterance reconnect")
    func reconnectsAfterDrop() async throws {
        let connects = Counter()
        let c = SpeechmaticsClient(apiKey: "k", connect: { _, _ in
            await connects.bump()
            return FakeWebSocketChannel(script: [serverMsg("Error", type: "temporary")])
        })
        try await c.prewarm()

        let s1 = try await c.beginUtterance(vocab: [])
        for await _ in s1 {} // drain to the server Error → session torn down, socket dropped

        let s2 = try await c.beginUtterance(vocab: [])
        for await _ in s2 {}

        // Reconnected each time rather than no-op'ing on a dead channel (the
        // STTClient reconnect contract).
        #expect(await connects.count == 2)
    }

    @Test("concurrent prewarm opens only one socket")
    func prewarmReentrancy() async throws {
        let connects = Counter()
        let c = SpeechmaticsClient(apiKey: "k", connect: { _, _ in
            await connects.bump()
            return FakeWebSocketChannel(script: [])
        })
        async let a: Void = c.prewarm()
        async let b: Void = c.prewarm()
        _ = try await (a, b)
        #expect(await connects.count == 1)
    }

    @Test("an idle-closed prewarmed socket self-heals on beginUtterance")
    func selfHealsIdleClosedSocket() async throws {
        let connects = Counter()
        let c = SpeechmaticsClient(apiKey: "k", connect: { _, _ in
            let n = await connects.bumpAndGet()
            // Socket #1 (prewarmed) is dead — rejects StartRecognition; #2 is healthy.
            return FakeWebSocketChannel(script: [serverMsg("EndOfTranscript")], failTextSend: n == 1)
        })
        try await c.prewarm()
        let stream = try await c.beginUtterance(vocab: []) // send fails → reconnect → socket #2
        for await _ in stream {}
        #expect(await connects.count == 2)
    }

    @Test("a second beginUtterance while the first is in flight throws .busy")
    func concurrentBeginBusy() async throws {
        let gate = Gate()
        let c = SpeechmaticsClient(apiKey: "k", connect: { _, _ in
            await gate.wait() // hold the first begin suspended at connect
            return FakeWebSocketChannel(script: [serverMsg("EndOfTranscript")])
        })
        async let first: AsyncStream<STTEvent> = c.beginUtterance(vocab: [])
        try await Task.sleep(for: .milliseconds(50)) // let the first begin claim `beginning`
        await #expect(throws: STTError.busy) { _ = try await c.beginUtterance(vocab: []) }
        await gate.openGate()
        let stream = try await first
        for await _ in stream {}
    }
}

@Suite("SpeechmaticsClient vocab + parsing")
struct SpeechmaticsClientVocabTests {

    @Test("additional_vocab preserves content and normalizes readings to full-width katakana")
    func vocabMapping() {
        let out = SpeechmaticsClient.additionalVocab(from: [
            STTVocabTerm(content: "議事録", soundsLike: ["ぎじろく"]),
            STTVocabTerm(content: "Koe", soundsLike: []),
        ])
        #expect(out.count == 2)
        #expect(out[0]["content"] as? String == "議事録")
        #expect(out[0]["sounds_like"] as? [String] == ["ギジロク"])
        #expect(out[1]["content"] as? String == "Koe")
        #expect(out[1]["sounds_like"] == nil) // omitted when no readings
    }

    @Test("half-width katakana readings widen to full-width")
    func halfWidthWidens() {
        #expect(SpeechmaticsClient.fullWidthKatakana("ｷﾞｼﾞﾛｸ") == "ギジロク")
    }

    @Test("additional_vocab is capped at the RT limit")
    func vocabCap() {
        let many = (0..<1500).map { STTVocabTerm(content: "w\($0)") }
        #expect(SpeechmaticsClient.additionalVocab(from: many).count == SpeechmaticsClient.vocabLimit)
    }

    @Test("parse classifies known and unknown messages")
    func parsing() {
        #expect(SpeechmaticsClient.parse(#"{"message":"EndOfTranscript"}"#) == .endOfTranscript)
        #expect(SpeechmaticsClient.parse(#"{"message":"RecognitionStarted"}"#) == .recognitionStarted)
        #expect(SpeechmaticsClient.parse(#"{"message":"Info"}"#) == .other)
        #expect(SpeechmaticsClient.parse("definitely not json") == .malformed)
        #expect(SpeechmaticsClient.parse(#"{"no_message":true}"#) == .malformed)
    }
}

// MARK: - Opt-in live integration (skips on CI / without a key or sample WAV)

@Suite("SpeechmaticsClient integration")
struct SpeechmaticsClientIntegrationTests {
    private var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["SPEECHMATICS_API_KEY"], !env.isEmpty {
            return env
        }
        return KeychainSecretStore().read(.speechmaticsAPIKey)
    }

    /// Streams a real 16kHz/mono/PCM16 WAV through the live RT socket.
    /// Run with: `KOE_STT_SAMPLE_WAV=<path> KOE_LIVE_TESTS=1 ./scripts/test.sh`
    /// The owner supplies the WAV (S2 recordings); absent any input it skips.
    @Test("transcribes a canned Japanese WAV into partials then a final")
    func liveTranscription() async throws {
        guard ProcessInfo.processInfo.environment["KOE_LIVE_TESTS"] != nil else { return }
        guard let key = apiKey else { return }
        guard let wavPath = ProcessInfo.processInfo.environment["KOE_STT_SAMPLE_WAV"],
              let wav = try? Data(contentsOf: URL(fileURLWithPath: wavPath)) else { return }

        let pcm = Self.pcmPayload(fromWav: wav)
        let c = SpeechmaticsClient(apiKey: key)
        try await c.prewarm()
        let stream = try await c.beginUtterance(vocab: [])

        // Feed ~64ms chunks (2048 bytes @16kHz PCM16), then end the utterance.
        let feeder = Task {
            var offset = 0
            let chunk = 2048
            while offset < pcm.count {
                let end = min(offset + chunk, pcm.count)
                try await c.send(audioChunk: pcm.subdata(in: offset..<end))
                offset = end
            }
            try await c.endUtterance()
        }

        var partials = 0
        var finals: [String] = []
        for await event in stream {
            switch event {
            case .partial: partials += 1
            case .final(let t): finals.append(t)
            case .error(let e): Issue.record("STT error: \(e)")
            }
        }
        try await feeder.value

        let transcript = finals.joined()
        print("=== Speechmatics ===\npartials=\(partials)\nfinal: \(transcript)\n====================")
        #expect(partials >= 1)
        #expect(!transcript.isEmpty)
        #expect(!transcript.contains("<transcript>"))
    }

    /// Return the PCM payload of a canonical WAV: locate the `data` sub-chunk,
    /// else fall back to skipping the standard 44-byte header.
    private static func pcmPayload(fromWav wav: Data) -> Data {
        let marker = Array("data".utf8)
        if let range = wav.range(of: Data(marker)) {
            let start = range.upperBound + 4 // skip the 4-byte chunk size
            if start <= wav.count { return wav.subdata(in: start..<wav.count) }
        }
        return wav.count > 44 ? wav.subdata(in: 44..<wav.count) : wav
    }
}
