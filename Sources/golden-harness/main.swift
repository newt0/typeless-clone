import Foundation
import KoeCore
import KoeGolden
import KoeProviders

// S3-T2 regression harness (plan 01-phase0-spikes.md §S3-T2).
//
// Usage:
//   GEMINI_API_KEY=... swift run golden-harness [--limit N] [--category cat]
//
// Stage (a) deterministic checks run per case; stage (b) LLM-as-judge is a
// separate pass (add --judge once a second provider key is configured).
// Exit code: 0 = all pass, 1 = failures, 2 = configuration error.

@main
struct GoldenHarness {
    static func main() async {
        let arguments = CommandLine.arguments
        func flag(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        guard let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] else {
            FileHandle.standardError.write(Data("GEMINI_API_KEY not set\n".utf8))
            exit(2)
        }

        var cases: [GoldenCase]
        do {
            cases = try GoldenSet.loadBundled()
        } catch {
            FileHandle.standardError.write(Data("failed to load golden set: \(error)\n".utf8))
            exit(2)
        }
        if let category = flag("--category") {
            cases = cases.filter { $0.category.rawValue == category }
        }
        if let limit = flag("--limit").flatMap(Int.init) {
            cases = Array(cases.prefix(limit))
        }

        let client = GeminiClient(apiKey: apiKey)
        var failures: [GoldenChecks.Failure] = []
        var passed = 0
        let started = Date()

        for (index, goldenCase) in cases.enumerated() {
            let formatter = LLMFormatter(
                client: client,
                style: goldenCase.writingStyle,
                dictionary: goldenCase.dictionaryEntries
            )
            do {
                let output = try await formatter.format(
                    goldenCase.input,
                    UtteranceContext(index: index)
                )
                if output.degraded {
                    failures.append(.init(caseID: goldenCase.id, reason: "degraded (validator rejected / LLM error)"))
                    print("✘ \(goldenCase.id): degraded")
                    continue
                }
                let caseFailures = GoldenChecks.evaluate(output.text, for: goldenCase)
                if caseFailures.isEmpty {
                    passed += 1
                    print("✔ \(goldenCase.id)")
                } else {
                    failures.append(contentsOf: caseFailures)
                    for failure in caseFailures { print("✘ \(failure)") }
                    print("   input : \(goldenCase.input)")
                    print("   output: \(output.text)")
                }
            } catch {
                failures.append(.init(caseID: goldenCase.id, reason: "error: \(error)"))
                print("✘ \(goldenCase.id): \(error)")
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        print("\n\(passed)/\(cases.count) passed in \(String(format: "%.1f", elapsed))s (prompt \(PromptTemplate.current.version))")
        exit(failures.isEmpty ? 0 : 1)
    }
}
