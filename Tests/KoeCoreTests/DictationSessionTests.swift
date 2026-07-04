import Testing
import Foundation
@testable import KoeCore

/// Deterministic clock: each read returns a time advanced by a fixed step, so
/// stamped metrics are strictly increasing without depending on wall time.
private final class StepClock: @unchecked Sendable {
    private var current: Date
    private let step: TimeInterval
    private let lock = NSLock()
    init(start: Date = Date(timeIntervalSince1970: 1_000), step: TimeInterval = 0.1) {
        current = start
        self.step = step
    }
    func next() -> Date {
        lock.lock(); defer { lock.unlock() }
        let value = current
        current = current.addingTimeInterval(step)
        return value
    }
}

private final class RecordingLogger: DictationEventLogger, @unchecked Sendable {
    private(set) var illegal: [(DictationState, DictationState)] = []
    private let lock = NSLock()
    func illegalTransition(from: DictationState, to: DictationState) {
        lock.lock(); defer { lock.unlock() }
        illegal.append((from, to))
    }
}

private func makeSession(
    _ clock: StepClock = StepClock(),
    logger: DictationEventLogger = NoopDictationEventLogger()
) -> DictationSession {
    DictationSession(now: { clock.next() }, logger: logger)
}

@Suite("DictationSession lifecycle")
struct DictationSessionTests {

    @Test("happy path idle→…→done→idle with monotonic metrics")
    func happyPath() async throws {
        let clock = StepClock()
        let session = makeSession(clock)

        try await session.startRecording()
        #expect(await session.state == .recording)
        try await session.endRecording()
        try await session.receiveFinalTranscript("明日送ります")
        #expect(await session.state == .formatting)
        #expect(await session.rawTranscript == "明日送ります")
        await session.noteFirstLLMToken()
        try await session.beginInsertion(text: "明日送ります。", degraded: false)
        #expect(await session.state == .inserting)
        try await session.completeInsertion(result: .pasted)
        #expect(await session.state == .done)
        try await session.finish()
        #expect(await session.state == .idle)

        let m = await session.metrics
        #expect(m.tKeyDown != nil)
        #expect(m.tKeyUp != nil)
        #expect(m.tSTTFinal != nil)
        #expect(m.tLLMFirstToken != nil)
        #expect(m.tInsertDone != nil)
        // End-to-end is stamped and positive.
        #expect((m.endToEnd ?? .zero) > .zero)
    }

    @Test("misfire cancel returns to idle and never feeds STT")
    func misfireDiscard() async throws {
        let session = makeSession()
        try await session.startRecording()
        try await session.cancel(reason: .misfire)
        #expect(await session.state == .idle)
        #expect(await session.cancelReason == .misfire)
        // A final transcript now is illegal: the machine cannot reach
        // formatting after a misfire, so STT output can never be consumed.
        await #expect(throws: DictationError.self) {
            try await session.receiveFinalTranscript("should be rejected")
        }
    }

    @Test("LLM failure degrades to raw transcript insertion")
    func degradationPath() async throws {
        let session = makeSession()
        try await session.startRecording()
        try await session.endRecording()
        try await session.receiveFinalTranscript("えーと明日")
        // Degraded: insert the raw transcript, not a formatted string.
        try await session.beginInsertion(text: "えーと明日", degraded: true)
        #expect(await session.degradedToRaw == true)
        #expect(await session.formattedText == "えーと明日")
        try await session.completeInsertion(result: .pasted)
        #expect(await session.state == .done)
    }

    @Test("STT failure routes to error then retry back to idle")
    func sttFailureRetry() async throws {
        let session = makeSession()
        try await session.startRecording()
        try await session.endRecording()
        try await session.sttFailed()
        #expect(await session.state == .error)
        try await session.retry()
        #expect(await session.state == .idle)
    }

    @Test("secure-input block is a valid insertion outcome")
    func secureInputBlocked() async throws {
        let session = makeSession()
        try await session.startRecording()
        try await session.endRecording()
        try await session.receiveFinalTranscript("secret")
        try await session.beginInsertion(text: "secret", degraded: false)
        try await session.completeInsertion(result: .blockedSecureInput)
        #expect(await session.insertResult == .blockedSecureInput)
    }

    @Test("illegal transition throws and is logged, state unchanged")
    func illegalTransitionLogged() async throws {
        let logger = RecordingLogger()
        let session = makeSession(logger: logger)
        // From idle, jumping straight to inserting is illegal.
        await #expect(throws: DictationError.illegalTransition(from: .idle, to: .inserting)) {
            try await session.beginInsertion(text: "x", degraded: false)
        }
        #expect(await session.state == .idle)
        #expect(logger.illegal.count == 1)
    }

    @Test("noteFirstLLMToken is ignored outside formatting")
    func firstTokenGuarded() async throws {
        let session = makeSession()
        await session.noteFirstLLMToken() // in idle → ignored
        #expect(await session.metrics.tLLMFirstToken == nil)
    }

    @Test("state stream replays current state then emits transitions")
    func stateStreamEmits() async throws {
        let session = makeSession()
        let stream = session.states // nonisolated let, no await needed
        let collector = Task<[DictationState], Never> {
            var collected: [DictationState] = []
            for await s in stream {
                collected.append(s)
                if s == .transcribing { break }
            }
            return collected
        }
        try await session.startRecording()
        try await session.endRecording()
        let collected = await collector.value
        #expect(collected == [.idle, .recording, .transcribing])
    }
}
