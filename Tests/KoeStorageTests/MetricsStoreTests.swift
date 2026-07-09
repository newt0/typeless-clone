import Testing
import Foundation
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
        let rate = try await store.redictationRate()
        #expect(rate == 1.0 / 3.0)
    }
}
