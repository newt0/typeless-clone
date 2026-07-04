import Testing
@testable import KoeCore

@Suite("DictationState transition table")
struct DictationStateTests {
    /// The exact legal edges from the Design §7.2 state diagram.
    static let legalEdges: [(DictationState, DictationState)] = [
        (.idle, .recording),
        (.recording, .transcribing),
        (.recording, .idle),
        (.transcribing, .formatting),
        (.transcribing, .error),
        (.formatting, .inserting),
        (.inserting, .done),
        (.error, .idle),
        (.done, .idle),
    ]

    @Test("every documented legal edge is permitted")
    func legalEdgesPermitted() {
        for (from, to) in Self.legalEdges {
            #expect(from.canTransition(to: to), "expected \(from)->\(to) legal")
        }
    }

    @Test("all edges not in the table are rejected")
    func illegalEdgesRejected() {
        let legal = Set(Self.legalEdges.map { "\($0.0)->\($0.1)" })
        for from in DictationState.allCases {
            for to in DictationState.allCases {
                let permitted = from.canTransition(to: to)
                let isLegal = legal.contains("\(from)->\(to)")
                #expect(permitted == isLegal, "mismatch for \(from)->\(to)")
            }
        }
    }

    @Test("self-transitions are never allowed")
    func noSelfLoops() {
        for s in DictationState.allCases {
            #expect(!s.canTransition(to: s))
        }
    }
}
