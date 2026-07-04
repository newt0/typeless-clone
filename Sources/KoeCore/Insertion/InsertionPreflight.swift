import Foundation

/// Why insertion was blocked for a secure context (invariant 3): nothing is
/// inserted AND nothing is written to the clipboard.
public enum SecureBlockReason: String, Sendable, Equatable {
    /// `IsSecureEventInputEnabled()` — a password field somewhere has secure
    /// event input on (Design §6.4).
    case secureEventInput
    /// The focused element is a `kAXSecureTextFieldSubrole` (Design §6.4).
    case secureField
}

/// Why insertion falls back to leaving text on the clipboard for the user.
public enum ClipboardHoldReason: String, Sendable, Equatable {
    /// The frontmost app changed between recording and insertion (Design §6.3-1).
    case appChanged
}

/// Outcome of the pre-insertion checks (Design §6.3-1, §6.4; plan M5-T1).
public enum PreflightDecision: Sendable, Equatable {
    /// Safe to attempt the paste (path 1).
    case proceed
    /// Abort entirely; do not paste and do not touch the clipboard.
    case blockedSecureInput(SecureBlockReason)
    /// Do not paste; leave the text on the clipboard + notify (path 3 landing).
    case clipboardHold(ClipboardHoldReason)
}

/// Pure decision for the insertion preflight. The runtime facts
/// (`IsSecureEventInputEnabled`, AX subrole read, frontmost bundle id) are
/// gathered by the app-layer `ContextProvider` (M5-T2); this function decides
/// what to do with them, so the safety policy is unit-testable.
public enum InsertionPreflight {
    public struct Facts: Sendable, Equatable {
        /// `IsSecureEventInputEnabled()`.
        public let secureEventInput: Bool
        /// Focused element is a secure field. `nil` means AX was unreadable —
        /// proceed optimistically (paste doesn't depend on the AX tree).
        public let focusedFieldSecure: Bool?
        /// Frontmost bundle id captured when recording started.
        public let recordingBundleID: String?
        /// Frontmost bundle id now, just before insertion.
        public let frontmostBundleID: String?

        public init(
            secureEventInput: Bool,
            focusedFieldSecure: Bool?,
            recordingBundleID: String?,
            frontmostBundleID: String?
        ) {
            self.secureEventInput = secureEventInput
            self.focusedFieldSecure = focusedFieldSecure
            self.recordingBundleID = recordingBundleID
            self.frontmostBundleID = frontmostBundleID
        }
    }

    public static func decide(_ facts: Facts) -> PreflightDecision {
        // Secure contexts win over everything: never insert, never copy.
        if facts.secureEventInput {
            return .blockedSecureInput(.secureEventInput)
        }
        if facts.focusedFieldSecure == true {
            return .blockedSecureInput(.secureField)
        }
        // Only hold when we can positively confirm the app changed.
        if let recording = facts.recordingBundleID,
           let frontmost = facts.frontmostBundleID,
           recording != frontmost {
            return .clipboardHold(.appChanged)
        }
        return .proceed
    }
}
