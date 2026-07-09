import Testing
import Foundation
@testable import KoeCore

// MARK: - Shared test doubles

/// Ordered event log across mocks, so relative ordering can be asserted.
private actor EventLog {
    private(set) var events: [String] = []
    func add(_ e: String) { events.append(e) }
}

private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }
}

private struct PassthroughAudio: AudioCapturing {
    func record(_ context: UtteranceContext) async throws -> AsyncThrowingStream<Data, any Error> {
        let data = Data("u\(context.index)".utf8)
        return AsyncThrowingStream { continuation in
            continuation.yield(data)
            continuation.finish()
        }
    }
}

private struct EchoTranscriber: Transcribing {
    func transcribe(
        _ audio: AsyncThrowingStream<Data, any Error>,
        _ context: UtteranceContext,
        onRecordingEnded: @escaping @Sendable () async -> Void
    ) async throws -> String {
        var collected = Data()
        for try await chunk in audio { collected.append(chunk) }
        await onRecordingEnded()
        return String(decoding: collected, as: UTF8.self)
    }
}

/// Fixed frontmost-app answer for every utterance.
private struct StaticFocus: ContextProviding {
    var bundleID: String?
    init(bundleID: String? = nil) { self.bundleID = bundleID }
    func frontmostBundleID() async -> String? { bundleID }
}

/// Returns the scripted bundle ids one per call — models the user switching
/// apps between two presses.
private actor SequencedFocus: ContextProviding {
    private var values: [String?]
    init(_ values: [String?]) { self.values = values }
    func frontmostBundleID() async -> String? {
        values.isEmpty ? nil : values.removeFirst()
    }
}

/// Records the UI-observer callbacks; collects each announced state stream.
private final class SpyUIObserver: DictationUIObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var _began: [Int] = []
    private var _landed: [InsertResult] = []
    private var _failed: [Int] = []
    private var _recoveries: [RecoveryHandle?] = []
    private var stateTasks: [Int: Task<[DictationState], Never>] = [:]

    var began: [Int] { lock.withLock { _began } }
    var landed: [InsertResult] { lock.withLock { _landed } }
    var failed: [Int] { lock.withLock { _failed } }
    var recoveries: [RecoveryHandle?] { lock.withLock { _recoveries } }

    func utteranceBegan(_ context: UtteranceContext, states: AsyncStream<DictationState>) {
        let task = Task {
            var seen: [DictationState] = []
            for await state in states { seen.append(state) }
            return seen
        }
        lock.withLock {
            _began.append(context.index)
            stateTasks[context.index] = task
        }
    }

    func utteranceLanded(_ context: UtteranceContext, result: InsertResult) {
        lock.withLock { _landed.append(result) }
    }

    func utteranceFailed(_ context: UtteranceContext, recovery: RecoveryHandle?) {
        lock.withLock {
            _failed.append(context.index)
            _recoveries.append(recovery)
        }
    }

    func collectedStates(forUtterance index: Int) async -> [DictationState] {
        let task = lock.withLock { stateTasks[index] }
        return await task?.value ?? []
    }
}

/// Captures the exact contexts insertion sees.
private actor ContextSpyInserter: TextInserting {
    private(set) var contexts: [UtteranceContext] = []
    func insert(_ output: PipelineOutput, _ context: UtteranceContext) async throws -> InsertResult {
        contexts.append(context)
        return .pasted
    }
}

/// Formats immediately unless `gateFor` matches the utterance index, in which
/// case it blocks until the gate opens — used to force pipeline overlap.
private struct GatedFormatter: Formatting {
    let gate: Gate?
    let gateFor: Int?
    func format(_ transcript: String, _ context: UtteranceContext) async throws -> PipelineOutput {
        if let gateFor, gateFor == context.index, let gate { await gate.wait() }
        return PipelineOutput(text: transcript + "!", degraded: false)
    }
}

/// Records insertion order; throws for utterances whose index is in `failIndices`.
private actor RecordingInserter: TextInserting {
    let log: EventLog
    let failIndices: Set<Int>
    init(log: EventLog, failIndices: Set<Int> = []) {
        self.log = log
        self.failIndices = failIndices
    }
    func insert(_ output: PipelineOutput, _ context: UtteranceContext) async throws -> InsertResult {
        if failIndices.contains(context.index) {
            throw DictationError.illegalTransition(from: .inserting, to: .inserting)
        }
        await log.add("insert:\(output.text)")
        return .pasted
    }
}

private actor SpyHistory: HistoryWriting {
    let log: EventLog
    init(log: EventLog) { self.log = log }
    func recordFinalTranscript(_ transcript: String, _ context: UtteranceContext) async -> UUID {
        await log.add("history.final:u\(context.index)")
        return UUID()
    }
    func updateFormatted(_ id: UUID, text: String) async { await log.add("history.formatted") }
    func updateInsertResult(_ id: UUID, result: InsertResult) async { await log.add("history.result") }
    func recordUntranscribedSession(_ context: UtteranceContext) async -> UUID {
        await log.add("history.untranscribed:u\(context.index)")
        return UUID()
    }
    func deleteRecord(_ id: UUID) async { await log.add("history.deleted") }
}

private func makeCoordinator(
    log: EventLog,
    serializer: InsertionSerializer,
    formatter: Formatting = GatedFormatter(gate: nil, gateFor: nil),
    failIndices: Set<Int> = []
) -> SessionCoordinator {
    SessionCoordinator(
        audio: PassthroughAudio(),
        stt: EchoTranscriber(),
        formatter: formatter,
        inserter: RecordingInserter(log: log, failIndices: failIndices),
        history: SpyHistory(log: log),
        focus: StaticFocus(),
        serializer: serializer
    )
}

// MARK: - Tests

@Suite("SessionCoordinator")
struct SessionCoordinatorTests {

    @Test("single utterance runs to completion with write-ahead before insert")
    func singleUtteranceWriteAhead() async {
        let log = EventLog()
        let coord = makeCoordinator(log: log, serializer: InsertionSerializer())
        let outcome = await (await coord.startUtterance()).value
        #expect(outcome == .completed(.pasted))
        let events = await log.events
        // Write-ahead: the final transcript is recorded before insertion.
        let finalIdx = events.firstIndex(of: "history.final:u0")
        let insertIdx = events.firstIndex(of: "insert:u0!")
        #expect(finalIdx != nil && insertIdx != nil)
        #expect(finalIdx! < insertIdx!)
        #expect(events.contains("history.result"))
    }

    @Test("two overlapping utterances insert in press order, not finish order")
    func fifoInsertionOrder() async {
        let log = EventLog()
        let gate = Gate()
        // Utterance 0's formatting blocks on the gate; utterance 1 formats
        // immediately and reaches the insertion gate first — yet must insert
        // after 0.
        let coord = makeCoordinator(
            log: log,
            serializer: InsertionSerializer(),
            formatter: GatedFormatter(gate: gate, gateFor: 0)
        )
        let t0 = await coord.startUtterance() // reserves ticket 0
        let t1 = await coord.startUtterance() // reserves ticket 1
        // Let utterance 1 run ahead and park behind the FIFO gate.
        await Task.yield()
        await gate.open()                     // unblock utterance 0's formatting
        _ = await t0.value
        _ = await t1.value

        let inserts = await log.events.filter { $0.hasPrefix("insert:") }
        #expect(inserts == ["insert:u0!", "insert:u1!"])
    }

    @Test("recording bundle id is captured at start and reaches insertion")
    func bundleIDReachesInsertion() async {
        let inserter = ContextSpyInserter()
        let coord = SessionCoordinator(
            audio: PassthroughAudio(),
            stt: EchoTranscriber(),
            formatter: GatedFormatter(gate: nil, gateFor: nil),
            inserter: inserter,
            history: SpyHistory(log: EventLog()),
            focus: StaticFocus(bundleID: "com.apple.TextEdit")
        )
        _ = await (await coord.startUtterance()).value
        #expect(await inserter.contexts.map(\.recordingBundleID) == ["com.apple.TextEdit"])
    }

    @Test("two utterances each carry the app they were spoken into")
    func perUtteranceBundleID() async {
        // The M5-T2 review gap: a shared "current frontmost app" closure could
        // not tell two overlapping utterances apart. Per-utterance capture must.
        let inserter = ContextSpyInserter()
        let coord = SessionCoordinator(
            audio: PassthroughAudio(),
            stt: EchoTranscriber(),
            formatter: GatedFormatter(gate: nil, gateFor: nil),
            inserter: inserter,
            history: SpyHistory(log: EventLog()),
            focus: SequencedFocus(["com.apple.TextEdit", "com.tinyspeck.slackmacgap"])
        )
        let t0 = await coord.startUtterance()
        let t1 = await coord.startUtterance()
        _ = await t0.value
        _ = await t1.value
        let byTicket = await inserter.contexts.sorted { $0.index < $1.index }
        #expect(byTicket.map(\.recordingBundleID) == ["com.apple.TextEdit", "com.tinyspeck.slackmacgap"])
    }

    @Test("the UI observer sees begin → states → landed for a successful utterance")
    func uiObserverLifecycle() async {
        let observer = SpyUIObserver()
        let coord = SessionCoordinator(
            audio: PassthroughAudio(),
            stt: EchoTranscriber(),
            formatter: GatedFormatter(gate: nil, gateFor: nil),
            inserter: RecordingInserter(log: EventLog()),
            history: SpyHistory(log: EventLog()),
            focus: StaticFocus(),
            ui: observer
        )
        _ = await (await coord.startUtterance()).value
        #expect(observer.began == [0])
        #expect(observer.landed == [.pasted])
        #expect(observer.failed.isEmpty)
        // The announced stream carries the utterance's transitions in order.
        let states = await observer.collectedStates(forUtterance: 0)
        #expect(states.starts(with: [.idle, .recording, .transcribing, .formatting, .inserting, .done]))
    }

    @Test("the UI observer sees a failure, not a landing, for a failed utterance")
    func uiObserverFailure() async {
        let observer = SpyUIObserver()
        let coord = SessionCoordinator(
            audio: PassthroughAudio(),
            stt: EchoTranscriber(),
            formatter: GatedFormatter(gate: nil, gateFor: nil),
            inserter: RecordingInserter(log: EventLog(), failIndices: [0]),
            history: SpyHistory(log: EventLog()),
            focus: StaticFocus(),
            ui: observer
        )
        _ = await (await coord.startUtterance()).value
        #expect(observer.failed == [0])
        #expect(observer.landed.isEmpty)
    }

    @Test("a failed insertion does not block the following utterance")
    func failedInsertDoesNotBlock() async {
        let log = EventLog()
        // Utterance 0's insertion throws; utterance 1 must still insert.
        let coord = makeCoordinator(
            log: log,
            serializer: InsertionSerializer(),
            failIndices: [0]
        )
        let o0 = await (await coord.startUtterance()).value
        let o1 = await (await coord.startUtterance()).value
        #expect(o0 == .failed(recovery: nil))
        #expect(o1 == .completed(.pasted))
        #expect(await log.events.contains("insert:u1!"))
    }
}

/// Streaming leg that exhausts the M4-T3 ladder with persisted audio.
private struct UnrecoveredTranscriber: Transcribing {
    func transcribe(
        _ audio: AsyncThrowingStream<Data, any Error>,
        _ context: UtteranceContext,
        onRecordingEnded: @escaping @Sendable () async -> Void
    ) async throws -> String {
        for try await _ in audio {}
        await onRecordingEnded()
        throw UnrecoveredUtterance(audioID: "audio-1")
    }
}

private actor FakeRecovery: RecoveryRetrying {
    private(set) var calls: [String] = []
    private(set) var discarded: [String] = []
    func retryTranscribe(audioID: String) async throws -> String {
        calls.append(audioID)
        return "再試行の文章"
    }
    func discardRecovered(audioID: String) async {
        discarded.append(audioID)
    }
}

@Suite("SessionCoordinator M4-T3 recovery")
struct SessionCoordinatorRecoveryTests {

    @Test("a double-fault records the audit row and surfaces a retry handle")
    func doubleFaultSurfacesRecovery() async {
        let log = EventLog()
        let observer = SpyUIObserver()
        let coord = SessionCoordinator(
            audio: PassthroughAudio(),
            stt: UnrecoveredTranscriber(),
            formatter: GatedFormatter(gate: nil, gateFor: nil),
            inserter: RecordingInserter(log: log),
            history: SpyHistory(log: log),
            focus: StaticFocus(),
            ui: observer
        )
        let outcome = await (await coord.startUtterance()).value
        guard case .failed(let recovery) = outcome, let recovery else {
            Issue.record("expected a retryable failure, got \(outcome)")
            return
        }
        #expect(recovery.audioID == "audio-1")
        #expect(await log.events.contains("history.untranscribed:u0"))
        // The UI observer received the same handle for its retry button.
        #expect(observer.recoveries == [recovery])
    }

    @Test("startRetry runs the post-STT pipeline and replaces the audit row")
    func retryPipeline() async {
        let log = EventLog()
        let recovery = FakeRecovery()
        let coord = SessionCoordinator(
            audio: PassthroughAudio(),
            stt: EchoTranscriber(),
            formatter: GatedFormatter(gate: nil, gateFor: nil),
            inserter: RecordingInserter(log: log),
            history: SpyHistory(log: log),
            focus: StaticFocus(),
            recovery: recovery
        )
        let handle = RecoveryHandle(audioID: "audio-9", historyID: UUID())
        guard let task = await coord.startRetry(handle) else {
            Issue.record("first retry must not be treated as a duplicate")
            return
        }
        let outcome = await task.value
        #expect(outcome == .completed(.pasted))
        let events = await log.events
        #expect(events.contains("insert:再試行の文章!"))
        // Audit row + WAV are discarded only after full completion.
        #expect(events.contains("history.deleted"))
        #expect(await recovery.calls == ["audio-9"])
        #expect(await recovery.discarded == ["audio-9"])
        // The in-flight guard has been released: a fresh retry is accepted.
        #expect(await coord.startRetry(handle) != nil)
    }

    @Test("a failed retry surfaces the SAME handle so retry stays available")
    func failedRetryKeepsHandle() async {
        let log = EventLog()
        let coord = SessionCoordinator(
            audio: PassthroughAudio(),
            stt: EchoTranscriber(),
            formatter: GatedFormatter(gate: nil, gateFor: nil),
            inserter: RecordingInserter(log: log),
            history: SpyHistory(log: log),
            focus: StaticFocus(),
            recovery: nil // retry unavailable → UnrecoveredUtterance(audioID: nil)
        )
        let handle = RecoveryHandle(audioID: "audio-9", historyID: UUID())
        guard let task = await coord.startRetry(handle) else {
            Issue.record("first retry must not be treated as a duplicate")
            return
        }
        // recovery seam absent → audio gone → not retryable
        #expect(await task.value == .failed(recovery: nil))
    }
}
