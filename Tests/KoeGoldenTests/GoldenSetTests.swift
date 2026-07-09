import Testing
import Foundation
@testable import KoeGolden
@testable import KoeCore

@Suite("GoldenSet")
struct GoldenSetTests {

    @Test("the bundled v1 set loads, has unique ids, and covers every category")
    func setShape() throws {
        let cases = try GoldenSet.loadBundled()
        #expect(cases.count >= 100)
        #expect(Set(cases.map(\.id)).count == cases.count)
        for category in GoldenCase.Category.allCases where category != .compound {
            let count = cases.filter { $0.category == category }.count
            #expect(count >= 10, "category \(category.rawValue) has \(count) cases (need >=10)")
        }
        #expect(cases.contains { $0.category == .compound })
        // must-NOT-convert list cases exist (§5.3 category 7 requirement).
        #expect(cases.contains { $0.category == .list && ($0.mustNotContain ?? []).contains("・") })
    }

    @Test("deterministic checks catch the failure classes they exist for")
    func checksCatchFailures() throws {
        let cases = try GoldenSet.loadBundled()
        let filler = try #require(cases.first { $0.id == "filler-01" })
        // Happy: a clean output passes.
        #expect(GoldenChecks.evaluate("明日の会議は10時からです。", for: filler).isEmpty)
        // Leftover filler → forbidden-substring failure.
        #expect(!GoldenChecks.evaluate("えーと、明日の会議は10時からです。", for: filler).isEmpty)
        // Preamble leakage.
        #expect(!GoldenChecks.evaluate("以下のように整形しました: 明日の会議は10時からです。", for: filler).isEmpty)
        // Empty output.
        #expect(!GoldenChecks.evaluate("   ", for: filler).isEmpty)
        // Dictionary spelling enforcement.
        let term = try #require(cases.first { $0.id == "term-01" })
        #expect(!GoldenChecks.evaluate("クロードコードでデプロイしておいてください。", for: term).isEmpty)
        #expect(GoldenChecks.evaluate("Claude Code でデプロイしておいてください。", for: term).isEmpty)
    }
}
