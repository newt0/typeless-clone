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

    init(script: [WSMessage]) { incoming = script }

    func send(text: String) async throws { sentText.append(text) }
    func send(binary: Data) async throws { sentBinary.append(binary) }

    func receive() async throws -> WSMessage {
        if incoming.isEmpty { throw STTError.connection } // reached only if a script omits EndOfTranscript
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
        let fake = FakeWebSocketChannel(script: [serverMsg("EndOfTranscript")])
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
