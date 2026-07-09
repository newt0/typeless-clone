import Testing
import Foundation
@testable import KoeCore

@Suite("HUDReducer")
struct HUDReducerTests {

    @Test("recording shows the live partial line and updates it")
    func recordingPartials() {
        var model = HUDReducer.reduce(.hidden, .state(.recording))
        #expect(model.phase == .recording(partial: ""))
        model = HUDReducer.reduce(model, .partial("こんに"))
        model = HUDReducer.reduce(model, .partial("こんにちは"))
        #expect(model.phase == .recording(partial: "こんにちは"))
    }

    @Test("a late partial cannot resurrect a dismissed panel")
    func latePartialIgnored() {
        let model = HUDReducer.reduce(.hidden, .partial("遅れて到着"))
        #expect(model.phase == .hidden)
    }

    @Test("transcribing/formatting/inserting collapse to the working phase")
    func workingPhases() {
        for state in [DictationState.transcribing, .formatting, .inserting] {
            let model = HUDReducer.reduce(HUDModel(phase: .recording(partial: "x")), .state(state))
            #expect(model.phase == .working)
        }
    }

    @Test("landing kind decides the outcome phase")
    func landingKinds() {
        #expect(HUDReducer.reduce(.hidden, .landed(.pasted)).phase == .done)
        #expect(HUDReducer.reduce(.hidden, .landed(.pastedViaAppleScript)).phase == .done)
        #expect(HUDReducer.reduce(.hidden, .landed(.clipboardFallback)).phase == .clipboardFallback)
        #expect(HUDReducer.reduce(.hidden, .landed(.blockedSecureInput)).phase == .secureBlocked)
        #expect(HUDReducer.reduce(.hidden, .failed).phase == .failed)
    }

    @Test("notices ride the secondary line without disturbing the phase")
    func noticeSecondLine() {
        let recording = HUDModel(phase: .recording(partial: "話し中"))
        let withNotice = HUDReducer.reduce(recording, .notice(.deviceSwitched(name: "MacBook Proのマイク")))
        #expect(withNotice.phase == .recording(partial: "話し中"))
        #expect(withNotice.notice == .deviceSwitched(name: "MacBook Proのマイク"))
        let cleared = HUDReducer.reduce(withNotice, .noticeDismissFired)
        #expect(cleared.phase == .recording(partial: "話し中"))
        #expect(cleared.notice == nil)
    }

    @Test("dwell policy: sticky while active, timed for outcomes, ⌘V lingers longest")
    func dwellPolicy() {
        #expect(HUDReducer.phaseDwell(.recording(partial: "")) == nil)
        #expect(HUDReducer.phaseDwell(.working) == nil)
        #expect(HUDReducer.phaseDwell(.done) == KoeConstants.hudDoneDwell)
        #expect(HUDReducer.phaseDwell(.clipboardFallback) == KoeConstants.hudClipboardDwell)
        #expect(HUDReducer.phaseDwell(.secureBlocked) == KoeConstants.hudNoticeDwell)
        #expect(HUDReducer.phaseDwell(.failed) == KoeConstants.hudNoticeDwell)
        if let clip = HUDReducer.phaseDwell(.clipboardFallback), let done = HUDReducer.phaseDwell(.done) {
            #expect(clip > done)
        }
    }

    @Test("phase dismiss hides the panel")
    func phaseDismiss() {
        let model = HUDReducer.reduce(HUDModel(phase: .done), .phaseDismissFired)
        #expect(model.phase == .hidden)
    }

    @Test("plain state noise (idle/done/error) does not change the phase")
    func stateNoiseIgnored() {
        let working = HUDModel(phase: .working)
        for state in [DictationState.idle, .done, .error] {
            #expect(HUDReducer.reduce(working, .state(state)).phase == .working)
        }
    }
}
