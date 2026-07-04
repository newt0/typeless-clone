import Testing
@testable import KoeCore

/// Mock LLM: returns a canned string or throws.
private struct MockLLM: LLMClient {
    enum Behavior { case reply(String), fail }
    let behavior: Behavior
    func complete(system: String, user: String) async throws -> String {
        switch behavior {
        case .reply(let s): return s
        case .fail: throw LLMError.http(status: 500)
        }
    }
}

private let ctx = UtteranceContext(index: 0)

@Suite("LLMFormatter")
struct LLMFormatterTests {

    @Test("good output is accepted, not degraded")
    func accepts() async {
        let f = LLMFormatter(client: MockLLM(behavior: .reply("明日送ります。")))
        let out = await f.format("えーと明日送ります", ctx)
        #expect(out == PipelineOutput(text: "明日送ります。", degraded: false))
    }

    @Test("LLM error degrades to the raw transcript")
    func errorDegrades() async {
        let f = LLMFormatter(client: MockLLM(behavior: .fail))
        let out = await f.format("えーと明日送ります", ctx)
        #expect(out == PipelineOutput(text: "えーと明日送ります", degraded: true))
    }

    @Test("empty LLM output degrades to raw")
    func emptyDegrades() async {
        let f = LLMFormatter(client: MockLLM(behavior: .reply("   ")))
        let out = await f.format("資料を送ります", ctx)
        #expect(out == PipelineOutput(text: "資料を送ります", degraded: true))
    }

    @Test("summarized output degrades to raw")
    func summarizationDegrades() async {
        let raw = String(repeating: "本", count: 100)
        let f = LLMFormatter(client: MockLLM(behavior: .reply(String(repeating: "本", count: 40))))
        let out = await f.format(raw, ctx)
        #expect(out.degraded)
        #expect(out.text == raw)
    }
}
