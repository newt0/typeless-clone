import Foundation
import GRDB
import KoeCore

/// One persisted metrics row. Numeric/enum/id columns only — the schema has
/// no body-text column by design (invariant 4; audited by a unit test).
public struct MetricsRow: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var createdAt: Date
    public var utterance: Int
    public var outcome: String
    public var degraded: Bool
    public var appBundleID: String?
    public var promptVersion: String
    public var provider: String
    public var sttFinalizeMs: Int?
    public var llmMs: Int?
    public var insertionMs: Int?
    public var endToEndMs: Int?

    public static let databaseTableName = "metrics"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Local-only metrics storage (plan M10-T2; Design §8.4). Nothing here ever
/// leaves the Mac; recording is skipped upstream when the user opted out.
public actor MetricsStore {
    private let dbQueue: DatabaseQueue

    public init(path: String) throws {
        self.dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    public static func inMemory() throws -> MetricsStore {
        try MetricsStore(dbQueue: DatabaseQueue())
    }

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_metrics") { db in
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
        }
        return migrator
    }

    public func record(_ sample: DictationSample, promptVersion: String, provider: String) async {
        let row = MetricsRow(
            id: nil,
            createdAt: sample.createdAt,
            utterance: sample.utterance,
            outcome: sample.outcome,
            degraded: sample.degraded,
            appBundleID: sample.appBundleID,
            promptVersion: promptVersion,
            provider: provider,
            sttFinalizeMs: sample.sttFinalizeMs,
            llmMs: sample.llmMs,
            insertionMs: sample.insertionMs,
            endToEndMs: sample.endToEndMs
        )
        do {
            try await dbQueue.write { db in
                var toInsert = row
                try toInsert.insert(db)
            }
        } catch {
            Log.error("metrics_write_failed", category: .history)
        }
    }

    /// Newest first.
    public func recent(limit: Int = 100) async throws -> [MetricsRow] {
        try await dbQueue.read { db in
            try MetricsRow.order(Column("createdAt").desc).limit(limit).fetchAll(db)
        }
    }

    /// Column names of the metrics table — the invariant-4 audit surface
    /// (a test asserts no body-text column ever appears here).
    public func columnNames() async throws -> [String] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(metrics)").map { $0["name"] as String }
        }
    }

    /// Rework proxy (§1.4): fraction of dictations followed by another into
    /// the SAME app within `window` seconds — over the most recent `limit`.
    public func redictationRate(within window: TimeInterval = 30, limit: Int = 100) async throws -> Double? {
        let rows = try await recent(limit: limit).sorted { $0.createdAt < $1.createdAt }
        guard rows.count >= 2 else { return nil }
        var followed = 0
        for (current, next) in zip(rows, rows.dropFirst()) {
            if let app = current.appBundleID, app == next.appBundleID,
               next.createdAt.timeIntervalSince(current.createdAt) <= window {
                followed += 1
            }
        }
        return Double(followed) / Double(rows.count - 1)
    }
}
