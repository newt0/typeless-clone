import Testing
import Foundation
@testable import KoeCore

/// Records the order in which values arrive.
private actor OrderLog {
    private(set) var items: [Int] = []
    func append(_ v: Int) { items.append(v) }
}

/// A one-shot gate a test can open to release a suspended task.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }
}

@Suite("InsertionSerializer FIFO gate")
struct InsertionSerializerTests {

    @Test("reserve hands out increasing tickets")
    func reserveIncrements() async {
        let s = InsertionSerializer()
        #expect(await s.reserve() == 0)
        #expect(await s.reserve() == 1)
        #expect(await s.reserve() == 2)
    }

    @Test("the first ticket may insert without waiting")
    func firstTicketImmediate() async {
        let s = InsertionSerializer()
        _ = await s.reserve()
        await s.waitTurn(0) // must not suspend forever
        await s.complete(0)
    }

    @Test("later ticket waits until earlier completes, regardless of arrival")
    func ordersOutOfArrivalOrder() async {
        let s = InsertionSerializer()
        _ = await s.reserve() // 0
        _ = await s.reserve() // 1
        let log = OrderLog()

        // Ticket 1 arrives at the gate first but must not proceed.
        let late = Task {
            await s.waitTurn(1)
            await log.append(1)
            await s.complete(1)
        }
        // Give the late task time to park on waitTurn(1).
        await Task.yield()

        // Now ticket 0 goes; completing it must release ticket 1.
        await s.waitTurn(0)
        await log.append(0)
        await s.complete(0)
        await late.value

        #expect(await log.items == [0, 1])
    }

    @Test("a waiter registered after its turn arrives still proceeds")
    func noLostWakeup() async {
        let s = InsertionSerializer()
        _ = await s.reserve() // 0
        _ = await s.reserve() // 1
        await s.waitTurn(0)
        await s.complete(0) // advances to serve 1 before anyone waits on it
        // Ticket 1 registers its wait only now; must return immediately.
        await s.waitTurn(1)
        await s.complete(1)
    }
}
