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
            // A typo'd category must not silently filter to zero and report a
            // false all-pass (review finding).
            guard let parsed = GoldenCase.Category(rawValue: category) else {
                let valid = GoldenCase.Category.allCases.map(\.rawValue).joined(separator: ", ")
                FileHandle.standardError.write(Data("unknown category '\(category)' (valid: \(valid))\n".utf8))
                exit(2)
            }
            cases = cases.filter { $0.category == parsed }
        }
        if let rawLimit = flag("--limit") {
            guard let limit = Int(rawLimit), limit > 0 else {
                FileHandle.standardError.write(Data("--limit must be a positive integer\n".utf8))
                exit(2)
            }
            cases = Array(cases.prefix(limit))
        }

        let client = GeminiClient(apiKey: apiKey)
        let assembler = PromptAssembler()
        var failures: [GoldenChecks.Failure] = []
        var passed = 0
        let started = Date()

        for goldenCase in cases {
            // Deliberately NOT through LLMFormatter: its runtime
            // OutputValidator applies a flat 30% shrink gate that rejects the
            // shrink-by-design categories (repetition/ITN/self-correction)
            // before the set's own category-aware checks ever run (review
            // finding). The harness owns its checks — GoldenChecks is the
            // single judge here.
            let prompt = assembler.assemble(
                transcript: goldenCase.input,
                style: goldenCase.writingStyle,
                dictionary: goldenCase.dictionaryEntries,
                frontmostApp: nil
            )
            do {
                // Generous per-request bound: this is a batch tool, not the
                // interactive 6s dictation budget (review finding).
                let output = try await Deadline.run(.seconds(30), onTimeout: { LLMError.timeout }) {
                    try await client.complete(system: prompt.system, user: prompt.user)
                }
                let caseFailures = GoldenChecks.evaluate(output, for: goldenCase)
                if caseFailures.isEmpty {
                    passed += 1
                    print("✔ \(goldenCase.id)")
                } else {
                    failures.append(contentsOf: caseFailures)
                    for failure in caseFailures { print("✘ \(failure)") }
                    print("   input : \(goldenCase.input)")
                    print("   output: \(output)")
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
