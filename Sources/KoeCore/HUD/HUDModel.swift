import Foundation

/// Transient, self-dismissing side notices (Design §7.5). Rendered as a
/// secondary line so they never fight the pipeline phase for the panel.
public enum HUDNotice: Sendable, Equatable {
    /// Mid-session input-device switch actually took effect (M3-T2 signal).
    case deviceSwitched(name: String)
    /// The 20-minute session cap stopped recording (M3-T1).
    case capReached
    /// An OLDER (non-current) utterance landed on the clipboard — the user
    /// must still see "press ⌘V", but on the secondary line so it can't
    /// clobber the live phase of the utterance they're currently speaking.
    case staleClipboardFallback
    /// An older utterance was blocked by secure input.
    case staleSecureBlocked
    /// An older utterance failed.
    case staleFailed
}

/// What the HUD panel is showing. UI is a pure projection of this value —
/// all decisions, including the multi-utterance overlap policy, live in
/// ``HUDReducer`` (testable, no AppKit).
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
        /// The utterance failed end-to-end (its transcript, if any, is in
        /// history). `recovery` non-nil = M4-T3 double-fault with persisted
        /// audio: the view offers a retry button for it.
        case failed(recovery: RecoveryHandle?)
    }

    public var phase: Phase
    public var notice: HUDNotice?
    /// The utterance whose lifecycle owns the phase line — the most recently
    /// began one (`-1` before the first). Older utterances' events are folded
    /// per the overlap policy in ``HUDReducer``.
    public var currentUtterance: Int

    public init(phase: Phase = .hidden, notice: HUDNotice? = nil, currentUtterance: Int = -1) {
        self.phase = phase
        self.notice = notice
        self.currentUtterance = currentUtterance
    }

    public static let hidden = HUDModel()
}

/// Everything that can change what the HUD shows. Utterance-scoped events
/// carry their FIFO ticket so the reducer — not the AppKit adapter — decides
/// whose events own the panel. Observer callbacks are NOT ordered across
/// utterances (a fast-failing later utterance can report before an earlier
/// slow one); the per-event ticket is what keeps the model coherent anyway.
public enum HUDEvent: Sendable, Equatable {
    /// A new utterance began; it takes ownership of the phase line.
    case began(utterance: Int)
    /// A pipeline state transition from an utterance's session.
    case state(utterance: Int, DictationState)
    /// A live partial transcript for an utterance's recording.
    case partial(utterance: Int, String)
    /// An utterance's insertion landed with this result.
    case landed(utterance: Int, InsertResult)
    /// An utterance failed (any stage); `recovery` non-nil = retryable
    /// double-fault (M4-T3).
    case failed(utterance: Int, recovery: RecoveryHandle?)
    case notice(HUDNotice)
    /// The phase dwell timer elapsed (scheduled per ``HUDReducer/phaseDwell(_:)``).
    case phaseDismissFired
    /// The notice dwell timer elapsed.
    case noticeDismissFired
}

/// Pure reduction of HUD events onto the model (Design §7.5: the panel renders
/// state, never decides it). The App-layer controller owns the timers; the
/// dwell and overlap policies live here so they are unit-tested.
///
/// Overlap policy: the most-recently-began utterance owns the phase line.
/// State/partial events from older utterances are dropped; their
/// action-relevant outcomes (clipboard landing / secure block / failure) fold
/// onto the notice line — visible without clobbering the live recording; a
/// quiet stale "done" is suppressed entirely.
public enum HUDReducer {
    public static func reduce(_ model: HUDModel, _ event: HUDEvent) -> HUDModel {
        var next = model
        switch event {
        case .began(let utterance):
            next.currentUtterance = utterance

        case .state(let utterance, let state):
            guard utterance == next.currentUtterance else { break }
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

        case .partial(let utterance, let text):
            // Only meaningful while the current recording line is up; a late
            // partial must not resurrect a dismissed panel.
            if utterance == next.currentUtterance, case .recording = next.phase {
                next.phase = .recording(partial: text)
            }

        case .landed(let utterance, let result):
            if utterance == next.currentUtterance {
                switch result {
                case .pasted, .pastedViaAppleScript:
                    next.phase = .done
                case .clipboardFallback:
                    next.phase = .clipboardFallback
                case .blockedSecureInput:
                    next.phase = .secureBlocked
                }
            } else {
                switch result {
                case .pasted, .pastedViaAppleScript:
                    break // a quiet stale "done" isn't worth interrupting for
                case .clipboardFallback:
                    next.notice = .staleClipboardFallback
                case .blockedSecureInput:
                    next.notice = .staleSecureBlocked
                }
            }

        case .failed(let utterance, let recovery):
            if utterance == next.currentUtterance {
                next.phase = .failed(recovery: recovery)
            } else {
                // The notice line can't host a button; a stale retryable
                // failure keeps its history row (and, within the session, the
                // stored audio) but loses the one-tap retry — documented P0
                // trade-off.
                next.notice = .staleFailed
            }

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
        case .secureBlocked, .failed(recovery: nil):
            return KoeConstants.hudNoticeDwell
        case .failed:
            // A retry button that vanishes in 2.5s is unusable; give the user
            // time to reach it (the failure stays retryable from history
            // anyway once M7-T2 ships).
            return KoeConstants.hudRetryDwell
        }
    }

    /// Notices always self-dismiss; the stale clipboard landing keeps the
    /// longer clipboard dwell for the same reason the phase version does.
    public static func noticeDwell(_ notice: HUDNotice) -> Duration {
        switch notice {
        case .staleClipboardFallback:
            return KoeConstants.hudClipboardDwell
        case .deviceSwitched, .capReached, .staleSecureBlocked, .staleFailed:
            return KoeConstants.hudNoticeDwell
        }
    }
}
