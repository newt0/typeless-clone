import Testing
import Foundation
@testable import KoeProviders
import KoeCore

/// Live integration against the Gemini API. Skips when no key is available
/// (e.g. CI, which is keyless) so the suite stays green; run locally with the
/// key in the Keychain to exercise the real request.
@Suite("GeminiClient integration")
struct GeminiClientTests {
    private var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !env.isEmpty {
            return env
        }
        return KeychainSecretStore().read(.geminiAPIKey)
    }

    @Test("formats a filler-laden Japanese transcript via the real API")
    func realFormatting() async throws {
        // Live test: opt-in only (keeps the default suite fast & keyless on CI).
        // Run with: KOE_LIVE_TESTS=1 ./scripts/test.sh
        guard ProcessInfo.processInfo.environment["KOE_LIVE_TESTS"] != nil else { return }
        guard let key = apiKey else { return } // no key → skip

        let client = GeminiClient(apiKey: key)
        let assembler = PromptAssembler()
        let transcript = "えーとですね、明日、いや明後日に資料を送りますので、よろしくお願いします"
        let prompt = assembler.assemble(transcript: transcript, style: .desuMasu)

        let output = try await client.complete(system: prompt.system, user: prompt.user)
        print("=== Gemini format ===\nIN : \(transcript)\nOUT: \(output)\n=====================")

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!trimmed.isEmpty)
        #expect(trimmed != transcript)          // it actually did something
        #expect(!trimmed.contains("<transcript>")) // no prompt leakage
    }
}
