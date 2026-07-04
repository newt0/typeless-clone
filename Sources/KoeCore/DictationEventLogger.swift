import Foundation

/// Logging seam for the core state machine (invariant 4: no body text).
///
/// KoeCore stays free of OSLog/AppKit; the app layer provides an OSLog-backed
/// implementation. Only event kinds and state names cross this boundary —
/// never transcripts, formatted text, or dictionary terms.
public protocol DictationEventLogger: Sendable {
    /// A programmer-error transition was attempted (Design §7.2).
    func illegalTransition(from: DictationState, to: DictationState)
}

/// No-op logger for tests and default construction.
public struct NoopDictationEventLogger: DictationEventLogger {
    public init() {}
    public func illegalTransition(from: DictationState, to: DictationState) {}
}
