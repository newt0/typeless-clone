import Foundation

/// Lifecycle state of a single dictation (Design §7.2).
///
/// The enum carries only the *kind* of state; payloads (transcript, formatted
/// text, insert result, error) live on ``DictationSession`` so the transition
/// table stays a simple state→state relation.
public enum DictationState: String, Sendable, Equatable, CaseIterable {
    case idle
    case recording
    case transcribing
    case formatting
    case inserting
    case done
    case error

    /// Legal transitions (Design §7.2 state diagram):
    ///
    /// - idle → recording        (hotkey down, connections prewarmed)
    /// - recording → transcribing (key up, end-of-utterance sent)
    /// - recording → idle         (cancel: Esc or <0.3s misfire discard)
    /// - transcribing → formatting (final transcript, write-ahead to history)
    /// - transcribing → error      (STT dead after resend)
    /// - formatting → inserting    (formatting done, or LLM failure → raw)
    /// - inserting → done          (inserted, or fallback landing)
    /// - error → idle              (retry)
    /// - done → idle               (reset for next utterance)
    func canTransition(to next: DictationState) -> Bool {
        switch (self, next) {
        case (.idle, .recording),
             (.recording, .transcribing),
             (.recording, .idle),
             (.transcribing, .formatting),
             (.transcribing, .error),
             (.formatting, .inserting),
             (.inserting, .done),
             (.error, .idle),
             (.done, .idle):
            return true
        default:
            return false
        }
    }
}

/// Why a recording was cancelled before reaching STT (Design §7.2).
public enum CancelReason: String, Sendable, Equatable {
    /// Press shorter than ``KoeConstants/misfireThreshold`` with no speech.
    case misfire
    /// User pressed Esc during recording.
    case userEscape
}

/// Outcome of the insertion stage (Design §6.2, §10.1).
public enum InsertResult: String, Sendable, Equatable {
    /// Path 1 paste simulation succeeded (or verification was not possible).
    case pasted
    /// Path 2 AppleScript keystroke succeeded.
    case pastedViaAppleScript
    /// Path 3 designed landing: left on clipboard, user pastes with ⌘V.
    case clipboardFallback
    /// Aborted for Secure Input / secure field; nothing inserted or copied.
    case blockedSecureInput
}

/// Errors raised by the dictation state machine.
public enum DictationError: Error, Equatable, Sendable {
    /// A transition not permitted by ``DictationState/canTransition(to:)`` was
    /// attempted. This is a programmer error; it is logged and thrown rather
    /// than asserted so it never crashes a user session and stays unit-testable
    /// (see docs/decisions.md 2026-07-04).
    case illegalTransition(from: DictationState, to: DictationState)
}
