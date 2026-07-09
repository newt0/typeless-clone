import Testing
import Foundation
@testable import KoeProviders
@testable import KoeCore

/// Scripted HTTP transport: pops one (status, body) per request and records
/// every request for assertions.
private actor ScriptedTransport {
    struct Recorded: Sendable {
        let url: String
        let method: String
        let auth: String?
        let body: Data?
    }
    private var script: [(status: Int, body: String)]
    private(set) var requests: [Recorded] = []

    init(_ script: [(status: Int, body: String)]) { self.script = script }

    func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(Recorded(
            url: request.url?.absoluteString ?? "",
            method: request.httpMethod ?? "",
            auth: request.value(forHTTPHeaderField: "Authorization"),
            body: request.httpBody
        ))
        guard !script.isEmpty else { throw STTError.connection }
        let step = script.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: step.status, httpVersion: nil, headerFields: nil
        )!
        return (Data(step.body.utf8), response)
    }
}

private func client(_ transport: ScriptedTransport) -> SpeechmaticsBatchClient {
    SpeechmaticsBatchClient(
        apiKey: "test-key",
        pollInterval: .milliseconds(1),
        transport: { try await transport.handle($0) }
    )
}

@Suite("SpeechmaticsBatchClient")
struct SpeechmaticsBatchClientTests {

    @Test("submit → poll running → done → transcript, with auth and multipart framing")
    func happyPath() async throws {
        let transport = ScriptedTransport([
            (201, #"{"id": "job-1"}"#),
            (200, #"{"job": {"id": "job-1", "status": "running"}}"#),
            (200, #"{"job": {"id": "job-1", "status": "done"}}"#),
            (200, "こんにちは、世界。\n"),
        ])
        let text = try await client(transport).transcribe(
            wav: Data("WAVBYTES".utf8),
            vocab: [STTVocabTerm(content: "世界", soundsLike: ["せかい"])]
        )
        #expect(text == "こんにちは、世界。")

        let requests = await transport.requests
        #expect(requests.count == 4)
        #expect(requests.allSatisfy { $0.auth == "Bearer test-key" })
        #expect(requests[0].method == "POST")
        let multipart = String(decoding: requests[0].body ?? Data(), as: UTF8.self)
        #expect(multipart.contains(#""language": "ja""#) || multipart.contains(#""language":"ja""#))
        #expect(multipart.contains("WAVBYTES"))
        #expect(multipart.contains("name=\"config\""))
        #expect(multipart.contains("name=\"data_file\""))
        #expect(multipart.contains("世界"))
        #expect(requests[3].url.contains("job-1/transcript") && requests[3].url.contains("format=txt"))
    }

    @Test("a rejected job throws a server error, not a hang")
    func rejectedJob() async {
        let transport = ScriptedTransport([
            (201, #"{"id": "job-2"}"#),
            (200, #"{"job": {"status": "rejected"}}"#),
        ])
        await #expect(throws: STTError.server(type: "rejected")) {
            _ = try await client(transport).transcribe(wav: Data(), vocab: [])
        }
    }

    @Test("rejected credentials surface as .auth")
    func authError() async {
        let transport = ScriptedTransport([(401, #"{"error": "unauthorized"}"#)])
        await #expect(throws: STTError.auth) {
            _ = try await client(transport).transcribe(wav: Data(), vocab: [])
        }
    }

    @Test("a malformed submit response is not treated as a job id")
    func malformedSubmit() async {
        let transport = ScriptedTransport([(201, "not json")])
        await #expect(throws: STTError.malformedResponse) {
            _ = try await client(transport).transcribe(wav: Data(), vocab: [])
        }
    }
}
