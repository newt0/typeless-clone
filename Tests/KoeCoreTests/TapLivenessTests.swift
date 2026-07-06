import Testing
@testable import KoeCore

@Suite("TapLiveness")
struct TapLivenessTests {
    @Test("trusted + enabled → healthy")
    func healthy() {
        #expect(TapLiveness.evaluate(trusted: true, tapEnabled: true) == .healthy)
    }

    @Test("trusted + disabled → needsReenable")
    func disabled() {
        #expect(TapLiveness.evaluate(trusted: true, tapEnabled: false) == .needsReenable)
    }

    @Test("untrusted → revoked regardless of enabled flag")
    func revokedDominates() {
        #expect(TapLiveness.evaluate(trusted: false, tapEnabled: true) == .revoked)
        #expect(TapLiveness.evaluate(trusted: false, tapEnabled: false) == .revoked)
    }
}
