import Foundation

/// `UserDefaults` keys for app-layer preferences, in one place so the current
/// reader and the future Settings UI (M10) can't silently desync on a typo'd
/// key string. Keys are stable identifiers — never rename once shipped.
enum AppDefaultsKey {
    /// Prefer the built-in mic over Bluetooth HFP (M3-T2). Absent ⇒ ON.
    static let preferBuiltInMic = "preferBuiltInMic"
}
