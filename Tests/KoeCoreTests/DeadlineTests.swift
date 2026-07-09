import Foundation
import Testing
@testable import KoeCore

private enum ProbeError: Error, Equatable { case boom, deadline }

@Suite("Deadline")
struct DeadlineTests {
    @Test("operation that finishes in time returns its value; deadline is not hit")
    func returnsValue() async throws {
        let value = try await Deadline.run(.seconds(10), onTimeout: { ProbeError.deadline }) {
            "ok"
        }
        #expect(value == "ok")
    }

    @Test("a slow operation is cut off and onTimeout() is thrown")
    func timesOut() async {
        await #expect(throws: ProbeError.deadline) {
            try await Deadline.run(.milliseconds(20), onTimeout: { ProbeError.deadline }) {
                try await Task.sleep(for: .seconds(60))
                return "unreachable"
            }
        }
    }

    @Test("an operation error propagates unchanged — never remapped to the timeout error")
    func passesThroughOperationError() async {
        await #expect(throws: ProbeError.boom) {
            try await Deadline.run(.seconds(10), onTimeout: { ProbeError.deadline }) {
                throw ProbeError.boom
            }
        }
    }

    @Test("caller cancellation propagates as CancellationError, not the timeout error")
    func cancellationIsNotTimeout() async {
        let task = Task {
            try await Deadline.run(.seconds(30), onTimeout: { ProbeError.deadline }) {
                try await Task.sleep(for: .seconds(60))
                return "unreachable"
            }
        }
        // Give the group time to start both children, then cancel the caller.
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        switch result {
        case .success:
            Issue.record("expected cancellation to throw, got a value")
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }
}
