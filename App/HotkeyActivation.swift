import KoeCore

/// Shared recording start/stop glue for the hotkey adapters (plan M2-T2).
///
/// Both ``FnHotkeyTap`` and ``AltHotkeyMonitor`` reduce key transitions through
/// their own ``HotkeyEngine`` and then run the resulting ``HotkeyAction`` through
/// this one helper, so the two hotkeys stay behaviourally identical (same log
/// events, same callbacks) — a change here can't silently diverge them.
@MainActor
struct HotkeyActivation {
    private let onStart: () -> Void
    private let onStop: () -> Void

    init(onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.onStart = onStart
        self.onStop = onStop
    }

    func apply(_ action: HotkeyAction) {
        switch action {
        case .start:
            Log.event("hotkey_recording_start", category: .hotkey)
            onStart()
        case .stop:
            Log.event("hotkey_recording_stop", category: .hotkey)
            onStop()
        case .none:
            break
        }
    }
}
