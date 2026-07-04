import Foundation
import GRDB

/// One dictation row (Design §7.7, §10.1). Written ahead in stages: the raw
/// transcript at final-transcript time, then formatted text, then insert result
/// — so a crash at any stage still leaves the transcript recoverable
/// (invariant 1).
public struct DictationRecord: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    /// Stable logical handle used by the pipeline to correlate the staged writes.
    public var uuid: String
    public var createdAt: Date
    public var rawText: String
    public var formattedText: String?
    public var appBundleID: String?
    /// `InsertResult.rawValue` once insertion resolves.
    public var insertResult: String?
    public var promptVersion: String?
    public var latencyMs: Int?
    public var degraded: Bool?
    /// User feedback signal (e.g. -1 for 👎), used as a rework-rate proxy.
    public var feedback: Int?

    public static let databaseTableName = "dictations"

    public init(
        id: Int64? = nil,
        uuid: String,
        createdAt: Date,
        rawText: String,
        formattedText: String? = nil,
        appBundleID: String? = nil,
        insertResult: String? = nil,
        promptVersion: String? = nil,
        latencyMs: Int? = nil,
        degraded: Bool? = nil,
        feedback: Int? = nil
    ) {
        self.id = id
        self.uuid = uuid
        self.createdAt = createdAt
        self.rawText = rawText
        self.formattedText = formattedText
        self.appBundleID = appBundleID
        self.insertResult = insertResult
        self.promptVersion = promptVersion
        self.latencyMs = latencyMs
        self.degraded = degraded
        self.feedback = feedback
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
