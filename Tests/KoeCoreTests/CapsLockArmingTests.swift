import Testing
@testable import KoeCore

@Suite("CapsLockArming")
struct CapsLockArmingTests {
    @Test("disabled is always off — no prompt, regardless of TCC state")
    func disabledIsOff() {
        for access in [InputMonitoringAccess.granted, .denied, .undetermined] {
            #expect(CapsLockArming.action(enabled: false, access: access) == .off)
        }
    }

    @Test("granted arms directly")
    func grantedArms() {
        #expect(CapsLockArming.action(enabled: true, access: .granted) == .arm)
    }

    @Test("undetermined requests access (one prompt) then arms")
    func undeterminedRequests() {
        #expect(CapsLockArming.action(enabled: true, access: .undetermined) == .requestAccessThenArm)
    }

    @Test("denied also requests — the check reports no-record as denied, and a real denial makes the request a no-op")
    func deniedStillRequests() {
        #expect(CapsLockArming.action(enabled: true, access: .denied) == .requestAccessThenArm)
    }
}
