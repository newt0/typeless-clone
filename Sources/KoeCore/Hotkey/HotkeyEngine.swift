import Foundation

/// Push-to-talk activation semantics for the global hotkey (Design §7.3; plan
/// M2-T1).
///
/// This is the pure, testable core of `HotkeyManager`: it turns a stream of
/// physical key transitions into start/stop commands, independent of the
/// CGEventTap that produces them. The tap wrapper (app target) decodes raw
/// `CGEvent`s into ``HotkeyTransition`` via ``FnKey`` and feeds them here.

/// How a hotkey press maps to recording (Design §7.3). Both are manual — no VAD
/// in Phase 0.
public enum HotkeyMode: Sendable, Equatable {
    /// Press-and-hold: record while the key is down, stop on release.
    case hold
    /// Tap-to-start / tap-to-stop: each press flips recording on or off.
    case toggle
}

/// A decoded physical transition of the bound hotkey. Modifier keys (Fn) never
/// emit key-down/up — they arrive as `flagsChanged` — so the tap layer resolves
/// the direction before handing it here (see ``FnKey``).
public enum HotkeyTransition: Sendable, Equatable {
    case down
    case up
}

/// The command the engine emits for a transition. `none` means the transition
/// is a no-op for the current mode/state (e.g. a key-up in `toggle`).
public enum HotkeyAction: Sendable, Equatable {
    case start
    case stop
    case none
}

/// Reduces hotkey transitions to start/stop commands. Value type: the tap holds
/// exactly one and mutates it on the tap thread (transitions are serialized by
/// the tap callback, so no locking is needed).
public struct HotkeyEngine: Sendable {
    public let mode: HotkeyMode
    /// Whether recording is currently active per this engine's bookkeeping. Kept
    /// so `toggle` can flip it and `hold` can ignore key-repeat style duplicates.
    public private(set) var isActive: Bool

    public init(mode: HotkeyMode) {
        self.mode = mode
        self.isActive = false
    }

    /// Advance the state machine and return the resulting command. Idempotent
    /// against duplicate transitions: a second `.down` while already active (or
    /// a `.up` while already stopped) yields `.none` rather than a spurious
    /// second start/stop.
    public mutating func handle(_ transition: HotkeyTransition) -> HotkeyAction {
        switch mode {
        case .hold:
            switch transition {
            case .down:
                guard !isActive else { return .none }
                isActive = true
                return .start
            case .up:
                guard isActive else { return .none }
                isActive = false
                return .stop
            }
        case .toggle:
            // Only key-down flips state; key-up is inert in toggle mode.
            guard transition == .down else { return .none }
            isActive.toggle()
            return isActive ? .start : .stop
        }
    }

    /// Force the engine back to the stopped state (e.g. the session was
    /// cancelled or the tap was rebuilt). Returns `.stop` when it was active so
    /// the caller can tear down an in-flight recording, else `.none`.
    public mutating func reset() -> HotkeyAction {
        guard isActive else { return .none }
        isActive = false
        return .stop
    }
}
