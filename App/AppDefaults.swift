import Foundation

/// `UserDefaults` keys for app-layer preferences, in one place so readers and
/// the Settings UI (M10) can't silently desync on a typo'd key string. Keys
/// are stable identifiers — never rename once shipped. API keys are NEVER
/// stored here (invariant 5: Keychain only).
enum AppDefaultsKey {
    /// Prefer the built-in mic over Bluetooth HFP (M3-T2). Absent ⇒ ON.
    static let preferBuiltInMic = "preferBuiltInMic"
    /// `WritingStyle` raw value. Absent ⇒ `.auto`.
    static let writingStyle = "writingStyle"
    /// LLM failure behavior: true ⇒ degraded output goes to the clipboard
    /// instead of being pasted raw. Absent ⇒ false (insert raw, invariant 2).
    static let degradedToClipboard = "degradedToClipboard"
    /// History auto-delete window in days; 0/absent ⇒ keep forever.
    static let historyRetentionDays = "historyRetentionDays"
    /// Local metrics collection opt-out (M10-T2 consumer). Absent ⇒ opted in.
    static let telemetryOptOut = "telemetryOptOut"
    /// Fn push-to-talk enabled. Absent ⇒ ON (⌥Space stays independent).
    static let fnHotkeyEnabled = "fnHotkeyEnabled"
    /// Per-app insertion overrides (M5-T3 table), JSON-encoded.
    static let insertionOverrides = "insertionOverrides"
}
