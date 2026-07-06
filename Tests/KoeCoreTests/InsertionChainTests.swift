import Foundation
import Testing
@testable import KoeCore

@Suite("InsertionPathPlanner")
struct InsertionPathPlannerTests {
    @Test("path 1 preference walks the full chain, ending on the clipboard landing")
    func fromPaste() {
        #expect(InsertionPathPlanner.plan(preferred: .paste) == [.paste, .appleScript, .clipboardOnly])
    }

    @Test("path 2 preference skips path 1 but keeps the clipboard landing")
    func fromAppleScript() {
        #expect(InsertionPathPlanner.plan(preferred: .appleScript) == [.appleScript, .clipboardOnly])
    }

    @Test("clipboard-only preference is a single terminal step")
    func fromClipboardOnly() {
        #expect(InsertionPathPlanner.plan(preferred: .clipboardOnly) == [.clipboardOnly])
    }

    @Test("every plan ends at the guaranteed clipboard landing")
    func alwaysEndsClipboard() {
        for preferred in InsertionPath.allCases {
            #expect(InsertionPathPlanner.plan(preferred: preferred).last == .clipboardOnly)
        }
    }
}

@Suite("InsertionOverrideTable")
struct InsertionOverrideTableTests {
    @Test("unknown app resolves to no override")
    func unknown() {
        let table = InsertionOverrideTable(["com.app.a": AppInsertionOverride(preferredPath: .appleScript)])
        #expect(table.override(for: "com.app.b") == nil)
        #expect(table.override(for: nil) == nil)
    }

    @Test("known app returns its override")
    func known() {
        let ov = AppInsertionOverride(preferredPath: .appleScript, extraPreDelay: .milliseconds(50))
        let table = InsertionOverrideTable(["com.app.a": ov])
        #expect(table.override(for: "com.app.a") == ov)
    }

    @Test("empty table resolves to nil (plain path-1 default)")
    func empty() {
        #expect(InsertionOverrideTable().override(for: "com.app.a") == nil)
    }
}

@Suite("InsertionChain fault injection")
struct InsertionChainTests {
    /// Records the paths attempted and drives each to a scripted outcome.
    private func run(
        _ plan: [InsertionPath],
        outcomes: [InsertionPath: PathAttempt]
    ) async -> (result: InsertResult, attempted: [InsertionPath]) {
        var attempted: [InsertionPath] = []
        let result = await InsertionChain.run(plan) { path in
            attempted.append(path)
            return outcomes[path] ?? .advance
        }
        return (result, attempted)
    }

    @Test("path 1 lands: only path 1 is attempted")
    func path1Lands() async {
        let (result, attempted) = await run(
            InsertionPathPlanner.plan(preferred: .paste),
            outcomes: [.paste: .landed(.pasted)]
        )
        #expect(result == .pasted)
        #expect(attempted == [.paste])
    }

    @Test("path 1 blocked → walks to path 2 which lands")
    func path1BlockedPath2Lands() async {
        let (result, attempted) = await run(
            InsertionPathPlanner.plan(preferred: .paste),
            outcomes: [.paste: .advance, .appleScript: .landed(.pastedViaAppleScript)]
        )
        #expect(result == .pastedViaAppleScript)
        #expect(attempted == [.paste, .appleScript])
    }

    @Test("paths 1 & 2 blocked → lands on path 3 (clipboard fallback)")
    func bothBlockedLandsPath3() async {
        let (result, attempted) = await run(
            InsertionPathPlanner.plan(preferred: .paste),
            outcomes: [
                .paste: .advance,
                .appleScript: .advance,
                .clipboardOnly: .landed(.clipboardFallback),
            ]
        )
        #expect(result == .clipboardFallback)
        #expect(attempted == [.paste, .appleScript, .clipboardOnly])
    }

    @Test("an exhausted chain still returns the clipboard-fallback floor")
    func exhaustedFloor() async {
        // Even if every path (defensively) advances, the result is the floor.
        let (result, attempted) = await run(
            InsertionPathPlanner.plan(preferred: .paste),
            outcomes: [:]
        )
        #expect(result == .clipboardFallback)
        #expect(attempted == [.paste, .appleScript, .clipboardOnly])
    }

    @Test("per-app override to path 2 skips path 1 entirely")
    func overrideSkipsPath1() async {
        let (result, attempted) = await run(
            InsertionPathPlanner.plan(preferred: .appleScript),
            outcomes: [.appleScript: .landed(.pastedViaAppleScript)]
        )
        #expect(result == .pastedViaAppleScript)
        #expect(attempted == [.appleScript])
    }
}
