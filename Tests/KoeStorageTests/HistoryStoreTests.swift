import Testing
import Foundation
@testable import KoeStorage
import KoeCore

/// Clock whose value the test sets between writes to control `createdAt`.
private final class SettableClock: @unchecked Sendable {
    private var value: Date
    private let lock = NSLock()
    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { value = start }
    func set(_ d: Date) { lock.lock(); value = d; lock.unlock() }
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
    func callAsFunction() -> Date { lock.lock(); defer { lock.unlock() }; return value }
}

private func makeStore(_ clock: SettableClock = SettableClock()) throws -> HistoryStore {
    try HistoryStore.inMemory(now: { clock() })
}

private let ctx = UtteranceContext(index: 0)

@Suite("HistoryStore")
struct HistoryStoreTests {

    @Test("write-ahead: the raw transcript survives before formatting/insertion")
    func writeAheadSurvives() async throws {
        let store = try makeStore()
        _ = await store.recordFinalTranscript("えーと明日送ります", ctx)
        // Nothing else happened (simulating a crash right after the transcript).
        let rows = try await store.recent()
        #expect(rows.count == 1)
        #expect(rows[0].rawText == "えーと明日送ります")
        #expect(rows[0].formattedText == nil)
        #expect(rows[0].insertResult == nil)
    }

    @Test("staged writes fill in formatted text then insert result")
    func stagedWrites() async throws {
        let store = try makeStore()
        let id = await store.recordFinalTranscript("えーと明日送ります", ctx)
        await store.updateFormatted(id, text: "明日送ります。")
        await store.updateInsertResult(id, result: .pasted)

        let row = try #require(try await store.recent().first)
        #expect(row.rawText == "えーと明日送ります")
        #expect(row.formattedText == "明日送ります。")
        #expect(row.insertResult == "pasted")
    }

    @Test("recent returns newest first")
    func recentOrdering() async throws {
        let clock = SettableClock(Date(timeIntervalSince1970: 1_000))
        let store = try makeStore(clock)
        let firstID = await store.recordFinalTranscript("古い", ctx)
        clock.advance(60)
        let secondID = await store.recordFinalTranscript("新しい", ctx)

        let rows = try await store.recent()
        #expect(rows.count == 2)
        #expect(rows[0].uuid == secondID.uuidString)
        #expect(rows[1].uuid == firstID.uuidString)
    }

    @Test("search finds Japanese substrings in raw and formatted text (≥3 chars → FTS)")
    func japaneseSubstringSearchFTS() async throws {
        let store = try makeStore()
        _ = await store.recordFinalTranscript("明日の会議は延期します", ctx)
        let id2 = await store.recordFinalTranscript("資料を送ります", ctx)
        await store.updateFormatted(id2, text: "資料を明日中に送付します。")

        // 3-char substring in raw text of record 1 (FTS path).
        let hits = try await store.search("は延期")
        #expect(hits.contains { $0.rawText == "明日の会議は延期します" })

        // 3-char substring only in formatted text of record 2.
        let formattedHit = try await store.search("明日中")
        #expect(formattedHit.contains { $0.uuid == id2.uuidString })

        // No match.
        #expect(try await store.search("宇宙船").isEmpty)
    }

    @Test("short (1–2 char) Japanese queries work via the LIKE fallback")
    func shortQuerySubstringSearch() async throws {
        let store = try makeStore()
        _ = await store.recordFinalTranscript("明日の会議は延期します", ctx)
        let id2 = await store.recordFinalTranscript("資料を送ります", ctx)
        await store.updateFormatted(id2, text: "資料を送付します。")

        // 2-char word in raw text.
        #expect(try await store.search("会議").contains { $0.rawText.contains("会議") })
        // 2-char word only in formatted text.
        #expect(try await store.search("送付").contains { $0.uuid == id2.uuidString })
        // 1-char search still matches.
        #expect(!(try await store.search("資").isEmpty))
        // Absent short query returns nothing.
        #expect(try await store.search("猫").isEmpty)
    }

    @Test("delete removes a row and drops it from the FTS index")
    func deleteRow() async throws {
        let store = try makeStore()
        let id = await store.recordFinalTranscript("消える会議の記録", ctx)
        try await store.delete(uuid: id)
        #expect(try await store.recent().isEmpty)
        #expect(try await store.search("会議").isEmpty)
    }

    @Test("deleteAll clears everything")
    func deleteAll() async throws {
        let store = try makeStore()
        _ = await store.recordFinalTranscript("あ会議あ", ctx)
        _ = await store.recordFinalTranscript("い会議い", ctx)
        try await store.deleteAll()
        #expect(try await store.recent().isEmpty)
    }

    @Test("deleteOlderThan prunes by retention window")
    func retentionPrune() async throws {
        let clock = SettableClock(Date(timeIntervalSince1970: 1_000_000))
        let store = try makeStore(clock)
        let oldID = await store.recordFinalTranscript("古い記録", ctx)
        clock.advance(10 * 86_400) // 10 days later
        let newID = await store.recordFinalTranscript("新しい記録", ctx)

        // Keep the last 3 days relative to "now".
        try await store.deleteOlderThan(days: 3, reference: clock())
        let rows = try await store.recent()
        #expect(rows.count == 1)
        #expect(rows[0].uuid == newID.uuidString)
        #expect(!rows.contains { $0.uuid == oldID.uuidString })
    }
}
