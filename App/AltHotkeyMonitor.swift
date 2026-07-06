import KeyboardShortcuts
import KoeCore

extension KeyboardShortcuts.Name {
    /// The Fn-alternative push-to-talk hotkey (plan M2-T2), default ⌥Space.
    /// User-remappable via a `KeyboardShortcuts.Recorder` in Settings (M10).
    static let dictation = Self("dictation", initial: .init(.space, modifiers: [.option]))
}

/// Alternative global hotkey for users who can't/won't use Fn (plan M2-T2).
///
/// Drives the same ``HotkeyEngine`` as ``FnHotkeyTap`` with identical
/// press-and-hold semantics, so a full dictation session is triggered the same
/// way regardless of which hotkey the user chose. Backed by the KeyboardShortcuts
/// library (Carbon `RegisterEventHotKey`) — no CGEventTap and no Input Monitoring
/// TCC; Accessibility is not required for this path.
@MainActor
final class AltHotkeyMonitor {
    private var engine: HotkeyEngine
    private let activation: HotkeyActivation

    init(mode: HotkeyMode = .hold, onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.engine = HotkeyEngine(mode: mode)
        self.activation = HotkeyActivation(onStart: onStart, onStop: onStop)
    }

    /// Register the down/up handlers. KeyboardShortcuts delivers these on the
    /// main actor, matching this class's isolation.
    func start() {
        KeyboardShortcuts.onKeyDown(for: .dictation) { [weak self] in
            guard let self else { return }
            self.activation.apply(self.engine.handle(.down))
        }
        KeyboardShortcuts.onKeyUp(for: .dictation) { [weak self] in
            guard let self else { return }
            self.activation.apply(self.engine.handle(.up))
        }
        Log.event("alt_hotkey_registered", category: .hotkey)
    }
}
