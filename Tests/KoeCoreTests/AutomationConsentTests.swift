import Foundation
import Testing
@testable import KoeCore

@Suite("AutomationConsent")
struct AutomationConsentTests {
    @Test("granted keeps the tight per-stage budget")
    func granted() {
        #expect(AutomationConsent.watchdogBudget(for: .granted) == KoeConstants.insertionStageTimeout)
    }

    @Test("denied skips the attempt — no budget at all")
    func denied() {
        #expect(AutomationConsent.watchdogBudget(for: .denied) == nil)
    }

    @Test("undetermined gets human-scale time to answer the consent dialog")
    func undetermined() {
        #expect(AutomationConsent.watchdogBudget(for: .undetermined) == KoeConstants.automationConsentTimeout)
    }

    @Test("the consent budget is far above the stage timeout — a 500ms kill would dismiss the dialog unanswered")
    func consentBudgetIsHumanScale() {
        #expect(KoeConstants.automationConsentTimeout >= .seconds(5))
        #expect(KoeConstants.automationConsentTimeout > KoeConstants.insertionStageTimeout)
    }
}
