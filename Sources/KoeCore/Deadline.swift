import Foundation

/// Runs an async operation under a total-time bound, distinguishing a genuine
/// deadline from caller cancellation (Design §10.3 timeout ladder).
///
/// The single shared primitive for the pipeline's timeout races (the LLM
/// total-time bound in ``LLMFormatter`` and the STT connect ping-verify in the
/// Speechmatics adapter), so the cancellation-ordering semantics are defined —
/// and tested — in exactly one place.
///
/// Semantics of ``run(_:onTimeout:operation:)``:
/// - `operation` completes first → its value is returned.
/// - `operation` throws → that error propagates unchanged (never remapped to
///   the timeout error), so a real failure is not misreported as a timeout.
/// - the deadline elapses while `operation` is still running → `onTimeout()` is
///   thrown and `operation` is cancelled.
/// - the calling task is cancelled → `CancellationError` propagates (NOT the
///   timeout error), because the deadline sleep is cancellation-propagating
///   (`try await`, not `try?`). This lets callers tell "the operation was slow"
///   apart from "the caller aborted".
public enum Deadline {
    public static func run<T: Sendable>(
        _ duration: Duration,
        onTimeout: @Sendable () -> any Error,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            // Deliberately `try await`, not `try?`: on caller cancellation this
            // sleep throws CancellationError, which propagates out as
            // CancellationError instead of being swallowed into a false timeout.
            group.addTask { try await Task.sleep(for: duration); return nil }
            defer { group.cancelAll() }
            // First child to finish decides the outcome. A non-nil result is the
            // operation's value; a nil result is the deadline sleep completing
            // normally (a genuine timeout); a thrown error (operation failure or
            // cancellation of either child) propagates via `next()`.
            while let result = try await group.next() {
                if let value = result { return value }
                throw onTimeout()
            }
            // Unreachable with two child tasks, but keep the type checker happy
            // and fail closed toward cancellation rather than a bogus timeout.
            throw CancellationError()
        }
    }
}
