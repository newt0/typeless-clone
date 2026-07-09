import Foundation
import Testing
@testable import KoeCore

/// Mock LLM: returns a canned string, throws, or hangs until cancelled.
private struct MockLLM: LLMClient {
    enum Behavior { case reply(String), fail, hang }
    let behavior: Behavior
    func complete(system: String, user: String) async throws -> String {
        switch behavior {
        case .reply(let s): return s
        case .fail: throw LLMError.http(status: 500)
        case .hang:
            // Sleeps far past any test timeout; cancellation (from the
            // formatter's deadline race, or a cancelled utterance) throws.
            try await Task.sleep(for: .seconds(60))
            return "unreachable"
        }
    }
}

private let ctx = UtteranceContext(index: 0)

@Suite("LLMFormatter")
struct LLMFormatterTests {

    @Test("good output is accepted, not degraded")
    func accepts() async throws {
        let f = LLMFormatter(client: MockLLM(behavior: .reply("明日送ります。")))
        let out = try await f.format("えーと明日送ります", ctx)
        #expect(out == PipelineOutput(text: "明日送ります。", degraded: false))
    }

    @Test("LLM error degrades to the raw transcript")
    func errorDegrades() async throws {
        let f = LLMFormatter(client: MockLLM(behavior: .fail))
        let out = try await f.format("えーと明日送ります", ctx)
        #expect(out == PipelineOutput(text: "えーと明日送ります", degraded: true))
    }

    @Test("empty LLM output degrades to raw")
    func emptyDegrades() async throws {
        let f = LLMFormatter(client: MockLLM(behavior: .reply("   ")))
        let out = try await f.format("資料を送ります", ctx)
        #expect(out == PipelineOutput(text: "資料を送ります", degraded: true))
    }

    @Test("summarized output degrades to raw")
    func summarizationDegrades() async throws {
        let raw = String(repeating: "本", count: 100)
        let f = LLMFormatter(client: MockLLM(behavior: .reply(String(repeating: "本", count: 40))))
        let out = try await f.format(raw, ctx)
        #expect(out.degraded)
        #expect(out.text == raw)
    }

    @Test("a hung LLM request times out and degrades to raw (§10.3 total-time leg)")
    func timeoutDegrades() async throws {
        let f = LLMFormatter(client: MockLLM(behavior: .hang), timeout: .milliseconds(50))
        let out = try await f.format("えーと明日送ります", ctx)
        #expect(out == PipelineOutput(text: "えーと明日送ります", degraded: true))
    }

    @Test("a cancelled utterance aborts (throws) rather than degrading and inserting")
    func cancellationAborts() async {
        // Long timeout so the deadline can't fire; only the caller's cancel does.
        let f = LLMFormatter(client: MockLLM(behavior: .hang), timeout: .seconds(30))
        let task = Task { try await f.format("えーと明日送ります", ctx) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        switch await task.result {
        case .success:
            // A cancelled utterance must NOT return a degraded output — that
            // would let the pipeline insert text the user cancelled.
            Issue.record("expected cancellation to throw, got a formatted output")
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }
}
