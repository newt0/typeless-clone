import Testing
import Foundation
import GRDB
@testable import KoeStorage
@testable import KoeCore

private func sample(at date: Date, app: String? = "com.apple.TextEdit", outcome: String = "pasted") -> DictationSample {
    var metrics = DictationMetrics()
    metrics.tKeyUp = date
    metrics.tInsertDone = date.addingTimeInterval(1.2)
    return DictationSample(
        createdAt: date, utterance: 0, outcome: outcome,
        degraded: false, appBundleID: app, metrics: metrics
    )
}

@Suite("MetricsStore")
struct MetricsStoreTests {

    @Test("record → recent round-trips the numeric row")
    func roundTrip() async throws {
        let store = try MetricsStore.inMemory()
        await store.record(sample(at: Date()), promptVersion: "1.0.0+abc", provider: "speechmatics+gemini")
        let rows = try await store.recent()
        #expect(rows.count == 1)
        #expect(rows[0].outcome == "pasted")
        #expect(rows[0].endToEndMs == 1200)
        #expect(rows[0].promptVersion == "1.0.0+abc")
    }

    @Test("schema carries no body-text column (invariant 4 audit)")
    func noTextColumns() async throws {
        let store = try MetricsStore.inMemory()
        let columns = try await store.columnNames()
        let forbidden = ["rawText", "formattedText", "transcript", "text"]
        #expect(columns.allSatisfy { name in
            !forbidden.contains { name.localizedCaseInsensitiveContains($0) }
        })
    }

    @Test("re-dictation rate counts same-app follow-ups within the window")
    func redictationRate() async throws {
        let store = try MetricsStore.inMemory()
        let base = Date(timeIntervalSince1970: 10_000)
        await store.record(sample(at: base), promptVersion: "v", provider: "p")
        await store.record(sample(at: base.addingTimeInterval(10)), promptVersion: "v", provider: "p")   // follow-up ≤30s
        await store.record(sample(at: base.addingTimeInterval(100)), promptVersion: "v", provider: "p")  // outside window
        await store.record(sample(at: base.addingTimeInterval(105), app: "com.other"), promptVersion: "v", provider: "p") // other app
        let rate = MetricsStore.redictationRate(rows: try await store.recent())
        #expect(rate == 1.0 / 3.0)
    }

    /// Regression: a database created by the shipped `v1_metrics` (no
    /// `isRetry`) must gain the column on open. `isRetry` was once added by
    /// editing `v1_metrics` in place — GRDB skips already-applied identifiers,
    /// so every real user's metrics write failed with "no such column" while
    /// fresh in-memory test DBs were unaffected. Found in owner QA.
    @Test("a database left at the shipped v1 shape upgrades and accepts writes")
    func upgradesLegacyV1Database() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("koe-metrics-v1-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Exactly what shipped as v1: no isRetry, and the identifier recorded
        // as applied so a re-registered v1 can never run again.
        let legacy = try DatabaseQueue(path: path)
        try await legacy.write { db in
            try db.execute(sql: """
                CREATE TABLE metrics (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    createdAt TEXT NOT NULL,
                    utterance INTEGER NOT NULL,
                    outcome TEXT NOT NULL,
                    degraded INTEGER NOT NULL,
                    appBundleID TEXT,
                    promptVersion TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    sttFinalizeMs INTEGER,
                    llmMs INTEGER,
                    insertionMs INTEGER,
                    endToEndMs INTEGER
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_metrics_createdAt ON metrics(createdAt);")
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);")
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v1_metrics');")
        }
        try await legacy.close()

        let store = try MetricsStore(path: path)
        await store.record(sample(at: Date()), promptVersion: "1.0.0+abc", provider: "speechmatics+gemini")
        let rows = try await store.recent()
        #expect(rows.count == 1)
        #expect(rows[0].isRetry == false)
        #expect(try await store.columnNames().contains("isRetry"))
    }
}
