import Carbon.HIToolbox
import CoreGraphics

/// Resolves the virtual keycode that produces "v" in the *current keyboard
/// layout* (Design §6.3-4). Hardcoding `kVK_ANSI_V` (9) works for QWERTY/JIS
/// (alphabetic keys keep QWERTY positions) but breaks on Dvorak/Colemak, so the
/// keycode is looked up via `TISCopyCurrentKeyboardLayoutInputSource` +
/// `UCKeyTranslate` (open-wispr's approach).
///
/// This is untestable system-API glue; the fallback keeps paste working even if
/// the layout can't be read (e.g. an IME input source with no Unicode key
/// layout data).
enum PasteKeyResolver {
    /// Keycode for "v" in the active layout, or `kVK_ANSI_V` if the layout is
    /// unreadable.
    static func vKeyCode() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return fallback
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { raw -> CGKeyCode in
            guard let base = raw.baseAddress else { return fallback }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for keyCode in UInt16(0)..<128 where character(for: keyCode, layout: layout) == "v" {
                return CGKeyCode(keyCode)
            }
            return fallback
        }
    }

    /// The unmodified character `keyCode` produces in `layout`, or nil.
    private static func character(for keyCode: UInt16, layout: UnsafePointer<UCKeyboardLayout>) -> String? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDown),
            0, // no modifier keys
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
