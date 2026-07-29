import Foundation

/// Recorded state of the Automation (AppleEvents → System Events) TCC
/// permission that path 2 needs, as reported by the OS at attempt time.
public enum AutomationPermissionState: Sendable, Equatable {
    /// The user already granted Automation for System Events.
    case granted
    /// The user already denied it; a run would fail without any dialog.
    case denied
    /// No decision recorded yet (first run, or TCC reset) — the attempt will
    /// put up the consent dialog. Also used when the state can't be read or
    /// System Events isn't running (cold launch), where the run needs the
    /// same generous budget.
    case undetermined
}

/// Pure decision: how long one path-2 `osascript` run may take before the
/// watchdog terminates it. Terminating the process dismisses a pending
/// consent dialog *without recording a decision*, so an undetermined state
/// must get enough budget for a human to answer the dialog — a 500ms kill
/// would re-trap every subsequent attempt and make path 2 permanently
/// unreachable (ultrareview PR #19 finding).
public enum AutomationConsent {
    /// Watchdog budget for the given permission state; `nil` means skip the
    /// attempt entirely (already denied — the chain advances immediately
    /// instead of burning the stage timeout on a guaranteed failure).
    public static func watchdogBudget(for state: AutomationPermissionState) -> Duration? {
        switch state {
        case .granted: return KoeConstants.insertionStageTimeout
        case .denied: return nil
        case .undetermined: return KoeConstants.automationConsentTimeout
        }
    }
}
