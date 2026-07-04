import Foundation
import KoeCore

/// `LLMClient` backed by the Gemini `generateContent` REST API (Design §4.2).
///
/// Thinking is disabled (`thinkingConfig.thinkingBudget = 0`) — this is a
/// rewrite task, not a reasoning task, and Gemini 2.5's default dynamic thinking
/// would blow up TTFT (Design §8).
public struct GeminiClient: LLMClient {
    private let apiKey: String
    private let model: String
    private let temperature: Double
    private let session: URLSession

    public init(
        apiKey: String,
        model: String = "gemini-2.5-flash-lite",
        temperature: Double = 0.2,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.session = session
    }

    public func complete(system: String, user: String) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": [
                "temperature": temperature,
                // Disable dynamic thinking for low TTFT.
                "thinkingConfig": ["thinkingBudget": 0],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.network }
        guard http.statusCode == 200 else { throw LLMError.http(status: http.statusCode) }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else {
            throw LLMError.malformedResponse
        }

        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw LLMError.empty }
        return text
    }
}
