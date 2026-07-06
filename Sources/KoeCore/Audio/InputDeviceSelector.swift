import Foundation

/// One microphone input device, described in the terms Koe's device-selection
/// policy cares about (Design §7.4; plan M3-T2).
///
/// Pure value mirrored from the App layer's CoreAudio enumeration: `id` is the
/// device UID (stable across reconnection, so it identifies "the same AirPods"
/// before and after a dropout), `transport` is the physical connection which is
/// what the built-in-preference actually keys on — Bluetooth HFP mics degrade
/// STT accuracy, so the default policy steers away from them.
public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    /// How the device is physically attached. Only ``builtIn`` vs everything
    /// else drives policy today; ``bluetooth`` is called out because HFP is the
    /// case we actively avoid.
    public enum Transport: Sendable, Equatable {
        case builtIn
        case bluetooth
        case usb
        case other
    }

    /// CoreAudio device UID — stable identity across disconnect/reconnect.
    public let id: String
    /// Human-readable name (for the HUD switch notice; never logged — invariant 4).
    public let name: String
    public let transport: Transport

    public init(id: String, name: String, transport: Transport) {
        self.id = id
        self.name = name
        self.transport = transport
    }

    /// True for the transports we prefer when "prefer built-in mic" is on.
    /// Only the Mac's own mic qualifies; USB/Bluetooth/other do not.
    public var isBuiltIn: Bool { transport == .builtIn }
}

/// What the capture engine should do after a mid-recording route change
/// (Design §7.4; plan M3-T2). Kept separate from ``AudioInputDevice`` so the
/// switch policy is unit-tested without a live `AVAudioEngine`.
public enum DeviceSwitchDecision: Sendable, Equatable {
    /// The best device is unchanged (or nothing better is available) — keep the
    /// current session running untouched.
    case keepCurrent
    /// Rebind capture to this device, continuing the *same* session (invariant
    /// 1: the transcript must cover audio from before and after the switch).
    case switchTo(AudioInputDevice)
}

/// Chooses which input device to record from, and whether a route change during
/// recording warrants switching (Design §7.4; plan M3-T2).
///
/// Two entry points share one preference: ``select(from:systemDefault:preferBuiltIn:)``
/// picks the device at recording start, and ``resolveSwitch(current:available:systemDefault:preferBuiltIn:)``
/// re-runs that same choice when the default-input route changes and reports
/// whether to act. Keeping both pure means the AirPods-dropout behaviour is
/// covered by fast unit tests rather than only manual QA.
public enum InputDeviceSelector {
    /// Pick the device to record from.
    ///
    /// - With `preferBuiltIn` on (the default), the Mac's built-in mic wins
    ///   whenever it is present — this is what keeps a freshly-connected
    ///   Bluetooth headset (HFP, poor for STT) from hijacking dictation. If no
    ///   built-in device is enumerated, fall back to the system default, then to
    ///   any available device.
    /// - With `preferBuiltIn` off, follow the system default (then any device),
    ///   so the user's explicit macOS choice is honoured.
    ///
    /// Returns `nil` only when no input device exists at all.
    public static func select(
        from available: [AudioInputDevice],
        systemDefault: AudioInputDevice?,
        preferBuiltIn: Bool
    ) -> AudioInputDevice? {
        if preferBuiltIn {
            // Prefer the built-in device; if the system default is already
            // built-in, keep that exact one so we don't reshuffle needlessly.
            if let def = systemDefault, def.isBuiltIn { return def }
            if let builtIn = available.first(where: { $0.isBuiltIn }) { return builtIn }
        }
        return systemDefault ?? available.first
    }

    /// After the default-input route changes mid-recording, decide whether to
    /// switch. Re-selects the preferred device and compares it to what we're
    /// recording on now.
    ///
    /// Yields ``DeviceSwitchDecision/keepCurrent`` when the preferred device is
    /// unchanged, or when nothing selectable remains (better to keep the current
    /// tap alive than tear the session down over a transient enumeration gap).
    public static func resolveSwitch(
        current: AudioInputDevice?,
        available: [AudioInputDevice],
        systemDefault: AudioInputDevice?,
        preferBuiltIn: Bool
    ) -> DeviceSwitchDecision {
        guard let target = select(from: available, systemDefault: systemDefault, preferBuiltIn: preferBuiltIn) else {
            return .keepCurrent
        }
        if let current, current.id == target.id { return .keepCurrent }
        return .switchTo(target)
    }
}
