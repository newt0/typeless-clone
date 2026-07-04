import Foundation

/// FIFO gate that serializes the *insertion* stage across concurrent
/// dictations (Design §10.4; plan M1-T2).
///
/// Utterances may pipeline freely (recording of N+1 while N formats), but a
/// later utterance must never write to the focused field before an earlier one
/// — two utterances interleaving at the cursor is a data-loss-class bug. Order
/// is fixed at hotkey-press time via ``reserve()``; each ticket then
/// ``waitTurn(_:)`` before inserting and ``complete(_:)`` after, in ticket
/// order.
///
/// Every reserved ticket MUST eventually complete (even cancelled/failed
/// utterances pass through `waitTurn` + `complete`) or the queue stalls; the
/// coordinator guarantees this on all paths.
public actor InsertionSerializer {
    private var nextTicket = 0
    private var nextToServe = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    public init() {}

    /// Reserve the next FIFO position. Call once per utterance at press time,
    /// in press order.
    public func reserve() -> Int {
        defer { nextTicket += 1 }
        return nextTicket
    }

    /// Suspend until it is this ticket's turn to insert. Returns immediately if
    /// the ticket is already the one being served.
    public func waitTurn(_ ticket: Int) async {
        if ticket == nextToServe { return }
        await withCheckedContinuation { continuation in
            // Runs synchronously within actor isolation before suspending, so
            // no wakeup from a concurrent complete() can be lost.
            waiters[ticket] = continuation
        }
    }

    /// Mark this ticket's insertion resolved, advancing the queue and waking the
    /// next waiter. Must be called after a matching ``waitTurn(_:)`` so tickets
    /// always complete in order.
    public func complete(_ ticket: Int) {
        precondition(ticket == nextToServe,
                     "insertion tickets must complete in FIFO order (got \(ticket), serving \(nextToServe))")
        nextToServe += 1
        if let continuation = waiters.removeValue(forKey: nextToServe) {
            continuation.resume()
        }
    }
}
