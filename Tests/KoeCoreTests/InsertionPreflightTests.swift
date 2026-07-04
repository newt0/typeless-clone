import Testing
@testable import KoeCore

@Suite("InsertionPreflight")
struct InsertionPreflightTests {
    private func facts(
        secureEventInput: Bool = false,
        focusedFieldSecure: Bool? = false,
        recording: String? = "com.app.a",
        frontmost: String? = "com.app.a"
    ) -> InsertionPreflight.Facts {
        .init(
            secureEventInput: secureEventInput,
            focusedFieldSecure: focusedFieldSecure,
            recordingBundleID: recording,
            frontmostBundleID: frontmost
        )
    }

    @Test("clean context proceeds")
    func proceeds() {
        #expect(InsertionPreflight.decide(facts()) == .proceed)
    }

    @Test("secure event input blocks (no clipboard) and wins over app change")
    func secureEventInputBlocks() {
        let d = InsertionPreflight.decide(
            facts(secureEventInput: true, recording: "com.app.a", frontmost: "com.app.b")
        )
        #expect(d == .blockedSecureInput(.secureEventInput))
    }

    @Test("secure field blocks")
    func secureFieldBlocks() {
        #expect(InsertionPreflight.decide(facts(focusedFieldSecure: true)) == .blockedSecureInput(.secureField))
    }

    @Test("unreadable AX (nil) proceeds optimistically")
    func unreadableAXProceeds() {
        #expect(InsertionPreflight.decide(facts(focusedFieldSecure: nil)) == .proceed)
    }

    @Test("frontmost app changed since recording holds on the clipboard")
    func appChangedHolds() {
        let d = InsertionPreflight.decide(facts(recording: "com.app.a", frontmost: "com.app.b"))
        #expect(d == .clipboardHold(.appChanged))
    }

    @Test("unknown bundle ids do not trigger a false app-change")
    func unknownBundlesProceed() {
        #expect(InsertionPreflight.decide(facts(recording: nil, frontmost: "com.app.b")) == .proceed)
        #expect(InsertionPreflight.decide(facts(recording: "com.app.a", frontmost: nil)) == .proceed)
    }

    @Test("secure input is checked before app change")
    func secureBeatsAppChange() {
        let d = InsertionPreflight.decide(
            facts(focusedFieldSecure: true, recording: "com.app.a", frontmost: "com.app.b")
        )
        #expect(d == .blockedSecureInput(.secureField))
    }
}
