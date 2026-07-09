import Foundation
import KoeCore
import os

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
    /// first audio frame. Verification is bounded by `timeout` so a silently
    /// stalled socket can never hang prewarm/beginUtterance forever.
    public static func connect(
        endpoint: URL,
        apiKey: String,
        session: URLSession = .shared,
        timeout: Duration = KoeConstants.sttConnectTimeout
    ) async throws -> WebSocketChannel {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.resume()
        let channel = URLSessionWebSocketChannel(task: task)
        try await channel.verify(timeout: timeout)
        return channel
    }

    private func verify(timeout: Duration) async throws {
        do {
            // Bound the ping by the connect timeout via the shared primitive. On
            // timeout `Deadline` cancels the ping child, whose cancellation
            // handler tears the socket down (`task.cancel`), and throws
            // STTError.connection; on caller cancellation it propagates
            // CancellationError instead of a false timeout.
            try await Deadline.run(timeout, onTimeout: { STTError.connection }) {
                try await self.ping()
            }
        } catch {
            // A rejected upgrade (bad/absent key) surfaces here; distinguish auth
            // from a generic transport failure via the captured HTTP response.
            if !(error is STTError),
               let status = (task.response as? HTTPURLResponse)?.statusCode,
               status == 401 || status == 403 {
                throw STTError.auth
            }
            throw STTError.from(error)
        }
    }

    /// Await a WebSocket ping; cancellation resumes the continuation (via the
    /// forced task cancel) so it never leaks when `verify` times out.
    ///
    /// The completion handler is latched to exactly one resume:
    /// `URLSessionWebSocketTask.sendPing` can invoke its handler more than
    /// once when the pong races a concurrent socket failure — and the
    /// `onCancel` teardown (`task.cancel`) widens exactly that window. The
    /// unlatched version crashed live (SIGTRAP double-resume in the launch
    /// prewarm, docs/decisions.md session 13).
    private func ping() async throws {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    let isFirst = resumed.withLock { alreadyResumed in
                        if alreadyResumed { return false }
                        alreadyResumed = true
                        return true
                    }
                    guard isFirst else { return }
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
        } onCancel: {
            task.cancel(with: .abnormalClosure, reason: nil)
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
    /// In-flight connect, shared by concurrent `prewarm`/`beginUtterance` so
    /// reentrancy across the `await` can't open (and leak) duplicate sockets.
    private var connectTask: Task<WebSocketChannel, Error>?
    /// Monotonic id of the live session; the receive loop only mutates shared
    /// state if its session is still current (a newer utterance may have
    /// replaced it).
    private var currentSession = 0
    /// True while a session is live and accepting audio (StartRecognition sent,
    /// EndOfStream not yet sent). Gates `send`/`endUtterance` so they can't act
    /// on a merely-prewarmed or already-ended session.
    private var accepting = false
    /// Synchronous mutex over `beginUtterance`: set at entry before any `await`,
    /// so overlapping begins can't open duplicate sockets or race receive loops.
    private var beginning = false

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
            try await URLSessionWebSocketChannel.connect(
                endpoint: $0, apiKey: $1, timeout: KoeConstants.sttConnectTimeout
            )
        }
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.language = language
        self.operatingPoint = operatingPoint
        // Guard the only Double we serialize: a non-finite max_delay would make
        // JSONSerialization fail (see jsonString).
        self.maxDelay = maxDelay.isFinite ? maxDelay : 1.0
        self.connect = connect
    }

    public func prewarm() async throws {
        _ = try await ensureChannel()
    }

    /// Return the current socket, opening one if needed. Reentrancy-safe: a
    /// second caller during the `await` joins the in-flight connect instead of
    /// starting its own.
    private func ensureChannel() async throws -> WebSocketChannel {
        if let channel { return channel }
        if let connectTask { return try await connectTask.value }

        let endpoint = self.endpoint
        let apiKey = self.apiKey
        let connect = self.connect
        let task = Task<WebSocketChannel, Error> {
            do { return try await connect(endpoint, apiKey) }
            catch { throw STTError.from(error) }
        }
        connectTask = task
        defer { connectTask = nil }
        let opened = try await task.value
        channel = opened
        Log.event("stt.prewarmed", category: .stt)
        return opened
    }

    public func beginUtterance(vocab: [STTVocabTerm]) async throws -> AsyncStream<STTEvent> {
        // Claim the begin synchronously (no `await` above this) so an overlapping
        // beginUtterance can't open a duplicate socket or spawn a racing loop.
        guard !beginning else { throw STTError.busy }
        beginning = true
        defer { beginning = false }

        // A still-live session means we're restarting mid-utterance: end its
        // stream and drop its (single-use) socket so this utterance gets a fresh
        // one. Nil `channel` *before* the `await close()` so nothing can reuse the
        // closing socket. Normal key-up flow leaves `continuation` nil (torn down
        // on EndOfTranscript), so this is skipped.
        if continuation != nil {
            finishCurrentSession()
            let stale = channel
            channel = nil
            await stale?.close()
        }

        let config = Self.startRecognitionMessage(
            language: language,
            operatingPoint: operatingPoint,
            maxDelay: maxDelay,
            vocab: vocab
        )
        let channel = try await openSession(config: config)

        currentSession += 1
        let session = currentSession
        seqNo = 0
        accepting = true

        let (stream, cont) = AsyncStream<STTEvent>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        receiveTask = Task { await self.receiveLoop(channel: channel, continuation: cont, session: session) }
        return stream
    }

    /// Get a channel and send StartRecognition on it. If the (possibly reused,
    /// idle-closed) socket rejects the send, drop it and reconnect once — this is
    /// how a prewarmed-then-idle connection self-heals without pinging the hot
    /// path on every utterance.
    private func openSession(config: String) async throws -> WebSocketChannel {
        let channel = try await ensureChannel()
        do {
            try await channel.send(text: config)
            return channel
        } catch {
            await channel.close()
            self.channel = nil
            let fresh = try await ensureChannel()
            do {
                try await fresh.send(text: config)
            } catch {
                self.channel = nil
                throw STTError.from(error)
            }
            return fresh
        }
    }

    public func send(audioChunk: Data) async throws {
        guard accepting, let channel else { throw STTError.notStarted }
        do { try await channel.send(binary: audioChunk) }
        catch { throw STTError.from(error) }
        seqNo += 1
    }

    public func endUtterance() async throws {
        guard accepting, let channel else { throw STTError.notStarted }
        accepting = false // reject any further send/endUtterance for this session
        do { try await channel.send(text: Self.endOfStreamMessage(lastSeqNo: seqNo)) }
        catch { throw STTError.from(error) }
        // Teardown (finish stream, drop the spent socket) happens in the receive
        // loop when the server confirms EndOfTranscript.
    }

    /// End the current stream without waiting for the server (restart/cancel).
    private func finishCurrentSession() {
        accepting = false
        receiveTask?.cancel()
        receiveTask = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: Receive loop (actor-isolated: resets state on termination)

    private func receiveLoop(
        channel: WebSocketChannel,
        continuation: AsyncStream<STTEvent>.Continuation,
        session: Int
    ) async {
        while !Task.isCancelled {
            let message: WSMessage
            do {
                message = try await channel.receive()
            } catch {
                endSession(session, yielding: .error(.connection), to: continuation)
                return
            }
            guard case .text(let text) = message else { continue } // ignore stray binary

            switch Self.parse(text) {
            case .recognitionStarted:
                Log.event("stt.recognition_started", category: .stt)
            case .partial(let t):
                if !t.isEmpty { continuation.yield(.partial(t)) }
            case .final(let t):
                if !t.isEmpty { continuation.yield(.final(t)) }
            case .endOfTranscript:
                endSession(session, yielding: nil, to: continuation)
                return
            case .serverError(let type):
                Log.error("stt.server_error", category: .stt)
                endSession(session, yielding: .error(.server(type: type)), to: continuation)
                return
            case .malformed:
                Log.error("stt.malformed", category: .stt)
                endSession(session, yielding: .error(.malformedResponse), to: continuation)
                return
            case .other:
                break // AudioAdded / Info / Warning / unknown — ignore
            }
        }
        // Cancelled: finishCurrentSession() already finished the continuation.
    }

    /// Finish the stream and, if this is still the current session, drop the
    /// spent/dead socket so the next prewarm/beginUtterance reconnects.
    private func endSession(
        _ session: Int,
        yielding event: STTEvent?,
        to continuation: AsyncStream<STTEvent>.Continuation
    ) {
        if let event { continuation.yield(event) }
        continuation.finish()
        guard session == currentSession else { return }
        accepting = false
        channel = nil
        self.continuation = nil
        receiveTask = nil
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
              let string = String(data: data, encoding: .utf8) else {
            // Inputs are controlled (strings/ints + a finite max_delay), so this
            // is unreachable in practice; log rather than silently ship "{}".
            Log.error("stt.encode_failed", category: .stt)
            return "{}"
        }
        return string
    }
}
