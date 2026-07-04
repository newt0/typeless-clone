import Foundation
import GRDB
import KoeCore

/// Personal-dictionary storage (Design §5.2, §7.7; plan M8). GRDB(SQLite), local
/// only. One term feeds both the LLM prompt and STT keyword boost through
/// ``promptEntries()`` / ``sttVocabulary()``, so the two consumers can never
/// drift out of sync.
public actor DictionaryStore {
    private let dbQueue: DatabaseQueue
    private let now: @Sendable () -> Date

    public init(path: String, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.dbQueue = try DatabaseQueue(path: path)
        self.now = now
        try Self.migrator.migrate(dbQueue)
    }

    public static func inMemory(now: @escaping @Sendable () -> Date = { Date() }) throws -> DictionaryStore {
        try DictionaryStore(dbQueue: DatabaseQueue(), now: now)
    }

    private init(dbQueue: DatabaseQueue, now: @escaping @Sendable () -> Date) throws {
        self.dbQueue = dbQueue
        self.now = now
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_dictionary") { db in
            try db.execute(sql: """
                CREATE TABLE dictionary (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    surface TEXT NOT NULL,
                    reading TEXT,
                    notes TEXT,
                    createdAt TEXT NOT NULL
                );
                """)
            // One row per surface form.
            try db.execute(sql: "CREATE UNIQUE INDEX idx_dictionary_surface ON dictionary(surface);")
        }
        return migrator
    }

    // MARK: CRUD

    /// Add a term. Throws if `surface` already exists (unique).
    @discardableResult
    public func add(surface: String, reading: String? = nil, notes: String? = nil) async throws -> DictionaryTerm {
        let term = DictionaryTerm(surface: surface, reading: reading, notes: notes, createdAt: now())
        return try await dbQueue.write { db in
            var toInsert = term
            try toInsert.insert(db)
            return toInsert
        }
    }

    /// Update an existing term (matched by `id`).
    public func update(_ term: DictionaryTerm) async throws {
        try await dbQueue.write { db in try term.update(db) }
    }

    public func delete(id: Int64) async throws {
        _ = try await dbQueue.write { db in try DictionaryTerm.deleteOne(db, key: id) }
    }

    public func deleteAll() async throws {
        _ = try await dbQueue.write { db in try DictionaryTerm.deleteAll(db) }
    }

    /// All terms, ordered by surface.
    public func all() async throws -> [DictionaryTerm] {
        try await dbQueue.read { db in
            try DictionaryTerm.order(Column("surface")).fetchAll(db)
        }
    }

    // MARK: Dual feed

    /// Terms for the LLM prompt block [4] (`PromptAssembler`).
    public func promptEntries() async throws -> [DictionaryEntry] {
        try await all().map(\.promptEntry)
    }

    /// Terms for STT keyword boost (M4 adapter).
    public func sttVocabulary() async throws -> [STTVocabTerm] {
        try await all().map(\.sttVocabTerm)
    }
}
