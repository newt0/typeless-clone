import Foundation

/// Transient, self-dismissing side notices (Design §7.5). Rendered as a
/// secondary line so they never fight the pipeline phase for the panel.
public enum HUDNotice: Sendable, Equatable {
    /// Mid-session input-device switch actually took effect (M3-T2 signal).
    case deviceSwitched(name: String)
    /// The 20-minute session cap stopped recording (M3-T1).
    case capReached
}

/// What the HUD panel is showing. UI is a pure projection of this value —
/// all decisions live in ``HUDReducer`` (testable, no AppKit).
public struct HUDModel: Sendable, Equatable {
    /// The pipeline phase line (primary content).
    public enum Phase: Sendable, Equatable {
        case hidden
        /// Recording, with the live partial transcript (may be empty).
        case recording(partial: String)
        /// STT finals settling / LLM formatting / insertion in flight.
        case working
        /// Landed by keystroke paste — flashes briefly, then hides.
        case done
        /// Designed landing: the text is on the clipboard for a manual ⌘V.
        case clipboardFallback
        /// Secure input context: nothing inserted, clipboard untouched.
        case secureBlocked
        /// The utterance failed end-to-end (text is in history).
        case failed
    }

    public var phase: Phase
    public var notice: HUDNotice?

    public init(phase: Phase = .hidden, notice: HUDNotice? = nil) {
        self.phase = phase
        self.notice = notice
    }

    public static let hidden = HUDModel()
}

/// Everything that can change what the HUD shows.
public enum HUDEvent: Sendable, Equatable {
    /// A pipeline state transition from the current utterance's session.
    case state(DictationState)
    /// A live partial transcript for the current recording.
    case partial(String)
    /// The utterance's insertion landed with this result.
    case landed(InsertResult)
    /// The utterance failed (any stage).
    case failed
    case notice(HUDNotice)
    /// The phase dwell timer elapsed (scheduled per ``HUDReducer/phaseDwell(_:)``).
    case phaseDismissFired
    /// The notice dwell timer elapsed.
    case noticeDismissFired
}

/// Pure reduction of HUD events onto the model (Design §7.5: the panel renders
/// state, never decides it). The App-layer controller owns the timers; the
/// dwell policy lives here so it is unit-tested.
public enum HUDReducer {
    public static func reduce(_ model: HUDModel, _ event: HUDEvent) -> HUDModel {
        var next = model
        switch event {
        case .state(let state):
            switch state {
            case .recording:
                next.phase = .recording(partial: "")
            case .transcribing, .formatting, .inserting:
                next.phase = .working
            case .idle, .done, .error:
                // Outcomes arrive via .landed/.failed, which carry the result
                // kind the state enum doesn't; plain state noise is ignored.
                break
            }
        case .partial(let text):
            // Partials are only meaningful while the recording line is up;
            // a late partial must not resurrect a dismissed panel.
            if case .recording = next.phase {
                next.phase = .recording(partial: text)
            }
        case .landed(let result):
            switch result {
            case .pasted, .pastedViaAppleScript:
                next.phase = .done
            case .clipboardFallback:
                next.phase = .clipboardFallback
            case .blockedSecureInput:
                next.phase = .secureBlocked
            }
        case .failed:
            next.phase = .failed
        case .notice(let notice):
            next.notice = notice
        case .phaseDismissFired:
            next.phase = .hidden
        case .noticeDismissFired:
            next.notice = nil
        }
        return next
    }

    /// How long a phase stays up before auto-dismissing. `nil` = sticky (the
    /// phase ends only via a later event). The clipboard landing lingers —
    /// the user has to notice "press ⌘V"; done just flashes (Design §7.5).
    public static func phaseDwell(_ phase: HUDModel.Phase) -> Duration? {
        switch phase {
        case .hidden, .recording, .working:
            return nil
        case .done:
            return KoeConstants.hudDoneDwell
        case .clipboardFallback:
            return KoeConstants.hudClipboardDwell
        case .secureBlocked, .failed:
            return KoeConstants.hudNoticeDwell
        }
    }

    /// Notices always self-dismiss.
    public static func noticeDwell(_ notice: HUDNotice) -> Duration {
        KoeConstants.hudNoticeDwell
    }
}
