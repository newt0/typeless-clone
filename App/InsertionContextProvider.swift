import AppKit
import ApplicationServices
import Carbon.HIToolbox
import KoeCore

/// Read-only context reads for the insertion preflight and verification
/// (Design §6.3-1, §6.3-5, §6.4; plan M5-T1 runtime half / M5-T2). Gathers the
/// runtime facts that the pure ``InsertionPreflight`` decision consumes (Secure
/// Input state, the focused element's secure-field subrole, the frontmost app's
/// bundle id) plus the focused element's value for best-effort paste
/// verification.
///
/// AX is used strictly read-only here (never `AXUIElementSetAttributeValue`);
/// an unreadable focus yields `nil` so callers proceed optimistically (paste
/// doesn't depend on the AX tree).
@MainActor
final class InsertionContextProvider: ContextProviding {
    /// Single system-wide element, reused across every focused-element fetch
    /// (this is a per-utterance hot path — no need to recreate it per read).
    private let systemWide = AXUIElementCreateSystemWide()

    init() {
        // Bound synchronous AX reads: an unresponsive target app must not hang
        // the main actor for the ~6s system default. Setting the timeout on the
        // system-wide element makes it the process-wide default for all AX
        // messaging; a timed-out read yields nil, which callers already treat
        // as "AX unreadable → proceed optimistically". See
        // ``KoeConstants/axReadTimeout`` for why the bound is generous.
        AXUIElementSetMessagingTimeout(
            systemWide,
            Float(KoeConstants.axReadTimeout / .seconds(1))
        )
    }

    /// `ContextProviding` seam used by the coordinator to capture the bundle id
    /// at recording start. Delegates to the sync read so both paths agree.
    func frontmostBundleID() async -> String? {
        currentFrontmostBundleID()
    }

    /// The single frontmost-app lookup, used by the async seam and the paste
    /// preflight alike.
    func currentFrontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Assemble the runtime facts for ``InsertionPreflight/decide(_:)``.
    /// `recordingBundleID` is the frontmost app captured when recording began
    /// (nil skips the app-change guard).
    func preflightFacts(recordingBundleID: String?) -> InsertionPreflight.Facts {
        InsertionPreflight.Facts(
            secureEventInput: IsSecureEventInputEnabled(),
            focusedFieldSecure: focusedFieldSecure(),
            recordingBundleID: recordingBundleID,
            frontmostBundleID: currentFrontmostBundleID()
        )
    }

    /// Whether the system-wide focused element is a secure text field. Returns
    /// `nil` when AX can't read the focus/subrole — the preflight then proceeds
    /// optimistically (Design §6.4).
    func focusedFieldSecure() -> Bool? {
        guard let element = focusedElement() else { return nil }
        var subroleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXSubroleAttribute as CFString, &subroleRef
              ) == .success,
              let subrole = subroleRef as? String
        else { return nil }
        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    /// The focused element's `AXValue` (or `AXSelectedText` fallback) for
    /// best-effort paste verification (Design §6.3-5), or nil if AX can't read
    /// it. Read-only.
    func focusedValueSnippet() -> String? {
        guard let element = focusedElement() else { return nil }
        for attribute in [kAXValueAttribute, kAXSelectedTextAttribute] {
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
               let string = valueRef as? String, !string.isEmpty {
                return string
            }
        }
        return nil
    }

    /// The system-wide focused UI element, or nil when AX is unreadable. Single
    /// source of the "get the focused AXUIElement" dance for every caller here.
    private func focusedElement() -> AXUIElement? {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
              ) == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        // Safe: the type id was just checked to be AXUIElement.
        return (focused as! AXUIElement)
    }
}
