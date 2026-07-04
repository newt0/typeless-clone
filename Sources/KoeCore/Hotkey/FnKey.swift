import Foundation

/// Decoding rules for the Fn / globe key as a push-to-talk hotkey (Design §7.3;
/// plan M2-T1).
///
/// The Fn key is a modifier: pressing it produces a `flagsChanged` CGEvent, not
/// a key-down/up pair. Both press and release arrive as the same event type and
/// key code (63 = `kVK_Function`); direction is read from whether the secondary-
/// Fn flag (`CGEventFlags.maskSecondaryFn`) is set afterwards. Keeping this
/// decode pure lets the tap wrapper stay a thin CGEvent adapter and lets tests
/// exercise the rules without synthesizing real events.
public enum FnKey {
    /// `kVK_Function`. The Fn key's virtual key code, reported on its
    /// `flagsChanged` event.
    public static let keyCode: Int64 = 63

    /// Resolve a `flagsChanged` event into a hotkey transition.
    ///
    /// - Parameters:
    ///   - keyCode: the event's `keyboardEventKeycode` field.
    ///   - secondaryFnActive: whether `CGEventFlags.maskSecondaryFn` is set on
    ///     the event's flags (true right after the key goes down).
    /// - Returns: `.down`/`.up` when this is the Fn key, or `nil` when it is a
    ///   different modifier the tap should pass through untouched.
    public static func transition(keyCode: Int64, secondaryFnActive: Bool) -> HotkeyTransition? {
        guard keyCode == Self.keyCode else { return nil }
        return secondaryFnActive ? .down : .up
    }
}
