import Foundation
import GRDB
import KoeCore

/// Local dictation history with write-ahead persistence and Japanese full-text
/// search (Design §7.7, §10.1; plan M7). GRDB(SQLite); the DB lives on the
/// user's Mac only (invariant 4). Conforms to ``HistoryWriting`` so the session
/// pipeline can write ahead.
///
/// Full-text search uses an FTS5 external-content index with the `trigram`
/// tokenizer, which gives substring matching for Japanese (no word
/// segmentation needed). Trigram requires queries of ≥3 characters.
public actor HistoryStore: HistoryWriting {
    private let dbQueue: DatabaseQueue
    private let now: @Sendable () -> Date

    /// Open (or create) the on-disk database at `path`.
    public init(path: String, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.dbQueue = try DatabaseQueue(path: path)
        self.now = now
        try Self.migrator.migrate(dbQueue)
    }

    /// In-memory store for tests and previews.
    public static func inMemory(now: @escaping @Sendable () -> Date = { Date() }) throws -> HistoryStore {
        try HistoryStore(dbQueue: DatabaseQueue(), now: now)
    }

    private init(dbQueue: DatabaseQueue, now: @escaping @Sendable () -> Date) throws {
        self.dbQueue = dbQueue
        self.now = now
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: Migrations

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_dictations") { db in
            try db.execute(sql: """
                CREATE TABLE dictations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    uuid TEXT NOT NULL UNIQUE,
                    createdAt TEXT NOT NULL,
                    rawText TEXT NOT NULL,
                    formattedText TEXT,
                    appBundleID TEXT,
                    insertResult TEXT,
                    promptVersion TEXT,
                    latencyMs INTEGER,
                    degraded INTEGER,
                    feedback INTEGER
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_dictations_createdAt ON dictations(createdAt);")

            // FTS5 external-content index over the text columns, trigram
            // tokenizer for Japanese substring search.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE dictations_ft USING fts5(
                    rawText, formattedText,
                    content='dictations', content_rowid='id',
                    tokenize='trigram'
                );
                """)
            // Keep the index in sync with staged writes (Design §10.1).
            try db.execute(sql: """
                CREATE TRIGGER dictations_ai AFTER INSERT ON dictations BEGIN
                    INSERT INTO dictations_ft(rowid, rawText, formattedText)
                    VALUES (new.id, new.rawText, new.formattedText);
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER dictations_ad AFTER DELETE ON dictations BEGIN
                    INSERT INTO dictations_ft(dictations_ft, rowid, rawText, formattedText)
                    VALUES ('delete', old.id, old.rawText, old.formattedText);
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER dictations_au AFTER UPDATE ON dictations BEGIN
                    INSERT INTO dictations_ft(dictations_ft, rowid, rawText, formattedText)
                    VALUES ('delete', old.id, old.rawText, old.formattedText);
                    INSERT INTO dictations_ft(rowid, rawText, formattedText)
                    VALUES (new.id, new.rawText, new.formattedText);
                END;
                """)
        }
        return migrator
    }

    // MARK: HistoryWriting (write-ahead, Design §10.1)

    public func recordFinalTranscript(_ transcript: String, _ context: UtteranceContext) async -> UUID {
        let uuid = UUID()
        let record = DictationRecord(uuid: uuid.uuidString, createdAt: now(), rawText: transcript)
        do {
            try await dbQueue.write { db in
                var toInsert = record
                try toInsert.insert(db)
            }
        } catch {
            Log.error("history_write_ahead_failed", category: .history)
        }
        return uuid
    }

    public func updateFormatted(_ id: UUID, text: String) async {
        await update(sql: "UPDATE dictations SET formattedText = ? WHERE uuid = ?", arguments: [text, id.uuidString])
    }

    public func updateInsertResult(_ id: UUID, result: InsertResult) async {
        await update(sql: "UPDATE dictations SET insertResult = ? WHERE uuid = ?", arguments: [result.rawValue, id.uuidString])
    }

    /// M4-T3 double-fault audit row: the utterance's audio could not be
    /// transcribed even by the batch resend. Empty `rawText`, no formatted
    /// text, no insert result — the M7-T2 UI renders it as an untranscribed
    /// session; a successful HUD retry deletes it via ``deleteRecord(_:)``.
    public func recordUntranscribedSession(_ context: UtteranceContext) async -> UUID {
        let uuid = UUID()
        let record = DictationRecord(uuid: uuid.uuidString, createdAt: now(), rawText: "")
        do {
            try await dbQueue.write { db in
                var toInsert = record
                try toInsert.insert(db)
            }
            Log.event("history_untranscribed_recorded", category: .history)
        } catch {
            Log.error("history_write_ahead_failed", category: .history)
        }
        return uuid
    }

    /// M7-T2 👎 feedback (rework-rate proxy metric, §1.4); `nil` clears it.
    public func updateFeedback(_ id: UUID, feedback: Int?) async {
        await update(sql: "UPDATE dictations SET feedback = ? WHERE uuid = ?", arguments: [feedback, id.uuidString])
    }

    public func deleteRecord(_ id: UUID) async {
        do {
            try await delete(uuid: id)
        } catch {
            Log.error("history_delete_failed", category: .history)
        }
    }

    private func update(sql: String, arguments: StatementArguments) async {
        do {
            try await dbQueue.write { db in
                try db.execute(sql: sql, arguments: arguments)
            }
        } catch {
            Log.error("history_update_failed", category: .history)
        }
    }

    /// 👎-rate inputs over the most recent `limit` rows (M10-T2 stats view).
    public func feedbackStats(limit: Int = 100) async throws -> (total: Int, down: Int) {
        try await dbQueue.read { db in
            let rows = try DictationRecord.order(Column("createdAt").desc).limit(limit).fetchAll(db)
            return (rows.count, rows.filter { $0.feedback == -1 }.count)
        }
    }

    // MARK: Queries (used by the history UI, M7-T2)

    /// Most recent dictations, newest first.
    public func recent(limit: Int = 100) async throws -> [DictationRecord] {
        try await dbQueue.read { db in
            try DictationRecord
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Substring search over raw and formatted text.
    ///
    /// Queries of ≥3 characters use the FTS5 trigram index (fast at scale);
    /// shorter queries fall back to a `LIKE` scan, because trigram cannot index
    /// 1–2 character terms and 2-character words are common in Japanese. Both
    /// paths match substrings, newest first.
    public func search(_ query: String, limit: Int = 100) async throws -> [DictationRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.count >= 3 {
            let phrase = "\"\(trimmed.replacingOccurrences(of: "\"", with: "\"\""))\""
            return try await dbQueue.read { db in
                try DictationRecord.fetchAll(db, sql: """
                    SELECT dictations.* FROM dictations
                    JOIN dictations_ft ON dictations_ft.rowid = dictations.id
                    WHERE dictations_ft MATCH ?
                    ORDER BY dictations.createdAt DESC
                    LIMIT ?
                    """, arguments: [phrase, limit])
            }
        } else {
            let like = "%\(escapeLike(trimmed))%"
            return try await dbQueue.read { db in
                try DictationRecord.fetchAll(db, sql: """
                    SELECT * FROM dictations
                    WHERE rawText LIKE ? ESCAPE '\\' OR formattedText LIKE ? ESCAPE '\\'
                    ORDER BY createdAt DESC
                    LIMIT ?
                    """, arguments: [like, like, limit])
            }
        }
    }

    private func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: Deletion / retention (Design §9.3)

    public func delete(uuid: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM dictations WHERE uuid = ?", arguments: [uuid.uuidString])
        }
    }

    public func deleteAll() async throws {
        try await dbQueue.write { db in try db.execute(sql: "DELETE FROM dictations") }
    }

    /// Delete rows older than `days`, relative to `reference` (defaults to now).
    public func deleteOlderThan(days: Int, reference: Date? = nil) async throws {
        let cutoff = (reference ?? now()).addingTimeInterval(-Double(days) * 86_400)
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM dictations WHERE createdAt < ?", arguments: [cutoff])
        }
    }
}
