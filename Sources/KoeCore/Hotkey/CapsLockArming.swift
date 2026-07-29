/// Recorded state of the Input Monitoring TCC permission, as reported by
/// `IOHIDCheckAccess` at arm time (owner-approved deviation from the original
/// "no Input Monitoring" stance — required for the Caps Lock hotkey; see
/// decisions.md session 14).
public enum InputMonitoringAccess: Sendable, Equatable {
    case granted
    case denied
    /// No decision recorded yet — arming should request (prompts once).
    case undetermined
}

/// What the Caps Lock monitor should do at arm time.
public enum CapsLockArmingAction: Sendable, Equatable {
    /// Feature disabled — do nothing, no permission prompt.
    case off
    /// Open the HID manager and listen.
    case arm
    /// Ask for Input Monitoring, then attempt to arm. `IOHIDRequestAccess`
    /// prompts only when no decision is recorded and silently returns false
    /// on a real denial — so requesting is always safe, and a mid-run grant
    /// may still need an app relaunch to take effect.
    case requestAccessThenArm
}

/// Pure decision: Caps Lock hotkey arming from the enabled flag × TCC state.
/// Mirrors ``TapLiveness`` — the untestable IOKit adapter stays a thin shell.
///
/// `denied` maps to request-then-arm, not a warn-only dead end: Input
/// Monitoring's check reports *no recorded decision* as denied (verified
/// live — a first-launch check returned denied and the prompt never showed),
/// and a real denial makes the request a harmless no-op. The denial surface
/// is the arm failure (⚠︎ + Settings caption), not a separate state.
public enum CapsLockArming {
    public static func action(enabled: Bool, access: InputMonitoringAccess) -> CapsLockArmingAction {
        guard enabled else { return .off }
        switch access {
        case .granted: return .arm
        case .undetermined, .denied: return .requestAccessThenArm
        }
    }
}
