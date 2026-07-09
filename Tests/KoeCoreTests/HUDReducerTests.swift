import Testing
import Foundation
@testable import KoeCore

/// Reduce a sequence of events from `.hidden`.
private func reduced(_ events: [HUDEvent]) -> HUDModel {
    events.reduce(HUDModel.hidden) { HUDReducer.reduce($0, $1) }
}

@Suite("HUDReducer")
struct HUDReducerTests {

    @Test("recording shows the live partial line and updates it")
    func recordingPartials() {
        let model = reduced([
            .began(utterance: 0),
            .state(utterance: 0, .recording),
            .partial(utterance: 0, "こんに"),
            .partial(utterance: 0, "こんにちは"),
        ])
        #expect(model.phase == .recording(partial: "こんにちは"))
    }

    @Test("a late partial cannot resurrect a dismissed panel")
    func latePartialIgnored() {
        let model = reduced([.began(utterance: 0), .partial(utterance: 0, "遅れて到着")])
        #expect(model.phase == .hidden)
    }

    @Test("transcribing/formatting/inserting collapse to the working phase")
    func workingPhases() {
        for state in [DictationState.transcribing, .formatting, .inserting] {
            let model = reduced([.began(utterance: 0), .state(utterance: 0, .recording), .state(utterance: 0, state)])
            #expect(model.phase == .working)
        }
    }

    @Test("landing kind decides the outcome phase for the current utterance")
    func landingKinds() {
        func landed(_ result: InsertResult) -> HUDModel.Phase {
            reduced([.began(utterance: 0), .landed(utterance: 0, result)]).phase
        }
        #expect(landed(.pasted) == .done)
        #expect(landed(.pastedViaAppleScript) == .done)
        #expect(landed(.clipboardFallback) == .clipboardFallback)
        #expect(landed(.blockedSecureInput) == .secureBlocked)
        #expect(reduced([.began(utterance: 0), .failed(utterance: 0)]).phase == .failed)
    }

    @Test("a stale failure cannot clobber the newer utterance's live recording")
    func staleFailureFoldsToNotice() {
        // Review finding: utterance 0 fails while utterance 1 is recording —
        // the recording line must survive and the failure ride the notice line.
        let model = reduced([
            .began(utterance: 0),
            .state(utterance: 0, .recording),
            .began(utterance: 1),
            .state(utterance: 1, .recording),
            .partial(utterance: 1, "話し中"),
            .failed(utterance: 0),
        ])
        #expect(model.phase == .recording(partial: "話し中"))
        #expect(model.notice == .staleFailed)
        // And the newer utterance's partials keep flowing afterwards.
        let after = HUDReducer.reduce(model, .partial(utterance: 1, "話し中です"))
        #expect(after.phase == .recording(partial: "話し中です"))
    }

    @Test("a stale clipboard landing folds to the notice line with the long dwell")
    func staleClipboardFoldsToNotice() {
        let model = reduced([
            .began(utterance: 0),
            .began(utterance: 1),
            .state(utterance: 1, .recording),
            .landed(utterance: 0, .clipboardFallback),
        ])
        #expect(model.phase == .recording(partial: ""))
        #expect(model.notice == .staleClipboardFallback)
        #expect(HUDReducer.noticeDwell(.staleClipboardFallback) == KoeConstants.hudClipboardDwell)
    }

    @Test("a quiet stale done is suppressed entirely")
    func staleDoneSuppressed() {
        let model = reduced([
            .began(utterance: 0),
            .began(utterance: 1),
            .state(utterance: 1, .recording),
            .landed(utterance: 0, .pasted),
        ])
        #expect(model.phase == .recording(partial: ""))
        #expect(model.notice == nil)
    }

    @Test("state and partial events from an older utterance are dropped")
    func staleStateDropped() {
        let model = reduced([
            .began(utterance: 0),
            .began(utterance: 1),
            .state(utterance: 1, .recording),
            .state(utterance: 0, .formatting),
            .partial(utterance: 0, "古い発話"),
        ])
        #expect(model.phase == .recording(partial: ""))
    }

    @Test("notices ride the secondary line without disturbing the phase")
    func noticeSecondLine() {
        let model = reduced([
            .began(utterance: 0),
            .state(utterance: 0, .recording),
            .partial(utterance: 0, "話し中"),
            .notice(.deviceSwitched(name: "MacBook Proのマイク")),
        ])
        #expect(model.phase == .recording(partial: "話し中"))
        #expect(model.notice == .deviceSwitched(name: "MacBook Proのマイク"))
        let cleared = HUDReducer.reduce(model, .noticeDismissFired)
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
        for state in [DictationState.idle, .done, .error] {
            let model = reduced([
                .began(utterance: 0),
                .state(utterance: 0, .formatting),
                .state(utterance: 0, state),
            ])
            #expect(model.phase == .working)
        }
    }
}
