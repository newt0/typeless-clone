import Foundation
import KoeCore

// MARK: - WebSocket transport seam

/// A message received over the WebSocket.
public enum WSMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

/// Minimal duplex WebSocket seam so ``SpeechmaticsClient`` is testable without a
/// live socket. The real implementation wraps `URLSessionWebSocketTask`; tests
/// inject a fake that scripts server messages and records sent frames.
public protocol WebSocketChannel: Sendable {
    func send(text: String) async throws
    func send(binary: Data) async throws
    /// Await the next inbound frame. Throws when the socket drops.
    func receive() async throws -> WSMessage
    func close() async
}

/// `URLSessionWebSocketTask`-backed channel. `URLSession`/its tasks are
/// documented thread-safe, so `@unchecked Sendable` is sound here.
public final class URLSessionWebSocketChannel: WebSocketChannel, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    private init(task: URLSessionWebSocketTask) { self.task = task }

    /// Open the connection (TLS + WS upgrade) and verify it with a ping so
    /// prewarm surfaces auth/handshake failures up front rather than on the
    /// first audio frame.
    public static func connect(
        endpoint: URL,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> WebSocketChannel {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.resume()
        let channel = URLSessionWebSocketChannel(task: task)
        try await channel.verify()
        return channel
    }

    private func verify() async throws {
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
        } catch {
            // A rejected upgrade (bad/absent key) surfaces here; distinguish auth
            // from a generic transport failure via the captured HTTP response.
            if let status = (task.response as? HTTPURLResponse)?.statusCode,
               status == 401 || status == 403 {
                throw STTError.auth
            }
            throw STTError.connection
        }
    }

    public func send(text: String) async throws { try await task.send(.string(text)) }
    public func send(binary: Data) async throws { try await task.send(.data(binary)) }

    public func receive() async throws -> WSMessage {
        switch try await task.receive() {
        case .string(let s): return .text(s)
        case .data(let d): return .binary(d)
        @unknown default: return .binary(Data())
        }
    }

    public func close() async { task.cancel(with: .normalClosure, reason: nil) }
}

// MARK: - Speechmatics realtime adapter (plan M4-T2)

/// ``STTClient`` backed by the Speechmatics Realtime (RT v2) WebSocket API
/// (Design §4.1). One socket serves one utterance: `StartRecognition` →
/// binary PCM16 chunks → `EndOfStream`; the server streams
/// `AddPartialTranscript`/`AddTranscript` and closes with `EndOfTranscript`.
///
/// Note (docs/decisions.md): the design's "ForceEndOfUtterance" message does
/// not exist in RT v2. For push-to-talk (key-up = definitive end) the correct
/// terminator is `EndOfStream { last_seq_no }`, which flushes the remaining
/// finals — that is what ``endUtterance()`` sends.
public actor SpeechmaticsClient: STTClient {
    // Speechmatics-specific defaults (provider-specific ⇒ not in KoeConstants).
    /// EU region endpoint. Japan RTT (~220ms) is a Phase-0/S2 measurement item;
    /// swap the region here once measured. [tune in Phase 0 / S2]
    public static let defaultEndpoint = URL(string: "wss://eu2.rt.speechmatics.com/v2")!
    /// `additional_vocab` hard cap (RT limit). Excess terms are dropped.
    public static let vocabLimit = 1000

    private let apiKey: String
    private let endpoint: URL
    private let language: String
    private let operatingPoint: String
    private let maxDelay: Double
    private let connect: @Sendable (URL, String) async throws -> WebSocketChannel

    private var channel: WebSocketChannel?
    private var seqNo = 0
    private var continuation: AsyncStream<STTEvent>.Continuation?
    private var receiveTask: Task<Void, Never>?

    /// - Parameters:
    ///   - maxDelay: seconds the server may buffer before emitting a final;
    ///     lower = snappier finals during speech. `EndOfStream` flushes
    ///     regardless at key-up. [tune in Phase 0 / S2]
    ///   - connect: transport factory (injectable for tests).
    public init(
        apiKey: String,
        endpoint: URL = SpeechmaticsClient.defaultEndpoint,
        language: String = "ja",
        operatingPoint: String = "enhanced",
        maxDelay: Double = 1.0,
        connect: @escaping @Sendable (URL, String) async throws -> WebSocketChannel = {
            try await URLSessionWebSocketChannel.connect(endpoint: $0, apiKey: $1)
        }
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.language = language
        self.operatingPoint = operatingPoint
        self.maxDelay = maxDelay
        self.connect = connect
    }

    public func prewarm() async throws {
        if channel != nil { return }
        do {
            channel = try await connect(endpoint, apiKey)
            Log.event("stt.prewarmed", category: .stt)
        } catch let error as STTError {
            throw error
        } catch {
            throw STTError.connection
        }
    }

    public func beginUtterance(vocab: [STTVocabTerm]) async throws -> AsyncStream<STTEvent> {
        if channel == nil { try await prewarm() }
        guard let channel else { throw STTError.connection }

        // Fresh session state.
        receiveTask?.cancel()
        seqNo = 0

        let config = Self.startRecognitionMessage(
            language: language,
            operatingPoint: operatingPoint,
            maxDelay: maxDelay,
            vocab: vocab
        )
        try await channel.send(text: config)

        let (stream, cont) = AsyncStream<STTEvent>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        receiveTask = Task { await Self.receiveLoop(channel: channel, continuation: cont) }
        return stream
    }

    public func send(audioChunk: Data) async throws {
        guard let channel else { throw STTError.notStarted }
        try await channel.send(binary: audioChunk)
        seqNo += 1
    }

    public func endUtterance() async throws {
        guard let channel else { throw STTError.notStarted }
        try await channel.send(text: Self.endOfStreamMessage(lastSeqNo: seqNo))
        // The receive loop keeps its own reference and drains the remaining
        // finals + EndOfTranscript. This socket is spent after EndOfStream, so
        // drop it — the next prewarm/beginUtterance opens a fresh one.
        self.channel = nil
        continuation = nil
        receiveTask = nil
    }

    // MARK: Receive loop (nonisolated: touches only Sendable values)

    private static func receiveLoop(
        channel: WebSocketChannel,
        continuation: AsyncStream<STTEvent>.Continuation
    ) async {
        while !Task.isCancelled {
            let message: WSMessage
            do {
                message = try await channel.receive()
            } catch {
                continuation.yield(.error(.connection))
                continuation.finish()
                return
            }
            guard case .text(let text) = message else { continue } // ignore stray binary

            switch parse(text) {
            case .recognitionStarted:
                Log.event("stt.recognition_started", category: .stt)
            case .partial(let t):
                if !t.isEmpty { continuation.yield(.partial(t)) }
            case .final(let t):
                if !t.isEmpty { continuation.yield(.final(t)) }
            case .endOfTranscript:
                continuation.finish()
                return
            case .serverError(let type):
                Log.error("stt.server_error", category: .stt)
                continuation.yield(.error(.server(type: type)))
                continuation.finish()
                return
            case .malformed:
                Log.error("stt.malformed", category: .stt)
                continuation.yield(.error(.malformedResponse))
                continuation.finish()
                return
            case .other:
                break // AudioAdded / Info / Warning / unknown — ignore
            }
        }
    }

    // MARK: Wire messages (static + pure ⇒ unit-testable)

    /// Client → server session opener. Smart-formatting/ITN options are omitted
    /// on purpose (invariant 8): all number/date normalization is the LLM's job.
    static func startRecognitionMessage(
        language: String,
        operatingPoint: String,
        maxDelay: Double,
        vocab: [STTVocabTerm]
    ) -> String {
        var transcription: [String: Any] = [
            "language": language,
            "operating_point": operatingPoint,
            "enable_partials": true,
            "max_delay": maxDelay,
        ]
        let additional = additionalVocab(from: vocab)
        if !additional.isEmpty { transcription["additional_vocab"] = additional }

        let body: [String: Any] = [
            "message": "StartRecognition",
            "audio_format": [
                "type": "raw",
                "encoding": "pcm_s16le",
                "sample_rate": 16000,
            ],
            "transcription_config": transcription,
        ]
        return jsonString(body)
    }

    static func endOfStreamMessage(lastSeqNo: Int) -> String {
        jsonString(["message": "EndOfStream", "last_seq_no": lastSeqNo])
    }

    /// `[STTVocabTerm]` → Speechmatics `additional_vocab`. `sounds_like` readings
    /// are normalized to full-width katakana (adapter responsibility per
    /// ``STTVocabTerm``); the list is capped at ``vocabLimit``.
    static func additionalVocab(from terms: [STTVocabTerm]) -> [[String: Any]] {
        if terms.count > vocabLimit {
            Log.event("stt.vocab_truncated", category: .stt, code: terms.count)
        }
        return terms.prefix(vocabLimit).map { term in
            var entry: [String: Any] = ["content": term.content]
            let sounds = term.soundsLike.map(fullWidthKatakana).filter { !$0.isEmpty }
            if !sounds.isEmpty { entry["sounds_like"] = sounds }
            return entry
        }
    }

    /// hiragana → katakana, then half-width kana → full-width.
    static func fullWidthKatakana(_ s: String) -> String {
        let katakana = s.applyingTransform(.hiraganaToKatakana, reverse: false) ?? s
        return katakana.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? katakana
    }

    enum Parsed: Equatable {
        case recognitionStarted
        case partial(String)
        case final(String)
        case endOfTranscript
        case serverError(type: String)
        case other
        case malformed
    }

    static func parse(_ text: String) -> Parsed {
        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? String
        else { return .malformed }

        switch message {
        case "RecognitionStarted":
            return .recognitionStarted
        case "AddPartialTranscript":
            return .partial(transcript(in: json))
        case "AddTranscript":
            return .final(transcript(in: json))
        case "EndOfTranscript":
            return .endOfTranscript
        case "Error":
            return .serverError(type: json["type"] as? String ?? "unknown")
        default:
            return .other
        }
    }

    private static func transcript(in json: [String: Any]) -> String {
        (json["metadata"] as? [String: Any])?["transcript"] as? String ?? ""
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
