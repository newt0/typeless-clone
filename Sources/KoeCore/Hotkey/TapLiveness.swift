import Foundation

/// The action a periodic CGEventTap liveness check should take (Design §7.3;
/// plan M2-T2).
///
/// A CGEventTap is "silently dying" prone: the OS can disable it (watchdog
/// timeout, user input during a hang) and Accessibility can be revoked at any
/// time. The tap runtime samples `AXIsProcessTrusted()` and the tap's enabled
/// flag on a timer; this enum is the decision those two booleans map to, kept
/// pure so it is unit-tested without a live tap.
public enum TapHealth: Sendable, Equatable {
    /// Trusted and enabled — no action.
    case healthy
    /// Trusted but the tap is disabled — re-enable it in place.
    case needsReenable
    /// Accessibility was revoked — tear the tap down and surface ⚠︎ +
    /// re-guidance (M11 hooks in here).
    case revoked
}

public enum TapLiveness {
    /// Map the two sampled booleans to a health verdict. Revocation dominates:
    /// an untrusted process cannot run a tap at all, so the enabled flag is
    /// irrelevant once trust is gone.
    public static func evaluate(trusted: Bool, tapEnabled: Bool) -> TapHealth {
        guard trusted else { return .revoked }
        return tapEnabled ? .healthy : .needsReenable
    }
}
