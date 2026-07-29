import AppKit
import IOKit.hid
import KoeCore

/// Caps Lock push-to-talk via a raw IOKit HID monitor (owner decision,
/// decisions.md session 14).
///
/// Why not a hotkey or CGEventTap: on this macOS generation, a `hidutil`
/// caps→F18 UserKeyMapping suppresses the caps toggle but emits **nothing**
/// (verified empirically — no Carbon hotkey, no typed key, for any
/// destination usage), and an un-remapped Caps Lock toggles the caps state
/// in the driver *before* any CGEventTap could consume it. Raw HID reports,
/// however, still carry the physical key (usage page 0x07 / usage 0x39
/// `kHIDUsage_KeyboardCapsLock`) below the remap layer — so the machine-local
/// suppressor mapping keeps the caps state inert while this monitor reads the
/// press/release directly.
///
/// Requires the Input Monitoring TCC (the app's only use of it; the pure
/// arming decision is ``CapsLockArming``). Same ``HotkeyEngine`` +
/// ``HotkeyActivation`` reduction as the other two hotkeys, so all three stay
/// behaviourally identical.
@MainActor
final class CapsLockHIDMonitor {
    private var engine: HotkeyEngine
    private let activation: HotkeyActivation
    private var manager: IOHIDManager?

    init(mode: HotkeyMode = .hold, onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.engine = HotkeyEngine(mode: mode)
        self.activation = HotkeyActivation(onStart: onStart, onStop: onStop)
    }

    /// Arm the monitor. Returns whether it is actually listening — `false`
    /// surfaces the ⚠︎ + panel guidance at the call site. Idempotent
    /// (M11 re-arm pattern): a second start while armed is a no-op success.
    func start() -> Bool {
        guard manager == nil else { return true }
        switch CapsLockArming.action(enabled: true, access: Self.currentAccess()) {
        case .off:
            return false
        case .arm:
            return arm()
        case .requestAccessThenArm:
            // One-time system prompt (no-op on a real recorded denial). A
            // grant made while the app runs often only takes effect after a
            // relaunch — try to arm anyway and let the failure path guide
            // the user (Settings caption says relaunch).
            Log.event("caps_access_requested", category: .permission)
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            return arm()
        }
    }

    /// Stop listening (Settings toggle off). The engine is rebuilt on the
    /// next `start()` so a mid-hold disable cannot leave a stale held state.
    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        self.engine = HotkeyEngine(mode: .hold)
        Log.event("caps_hotkey_stopped", category: .hotkey)
    }

    static func currentAccess() -> InputMonitoringAccess {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .undetermined
        }
    }

    private func arm() -> Bool {
        let created = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let keyboards: [[String: Int]] = [[
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard,
        ]]
        IOHIDManagerSetDeviceMatchingMultiple(created, keyboards as CFArray)

        // C callback: no captures allowed — thread `self` through the context
        // pointer. The manager is scheduled on the main run loop, so the
        // callback is main-actor by construction (same argument as the
        // CGEventTap callback in FnHotkeyTap).
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(created, { context, _, _, value in
            guard let context else { return }
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad),
                  IOHIDElementGetUsage(element) == UInt32(kHIDUsage_KeyboardCapsLock)
            else { return }
            let pressed = IOHIDValueGetIntegerValue(value) != 0
            MainActor.assumeIsolated {
                Unmanaged<CapsLockHIDMonitor>.fromOpaque(context)
                    .takeUnretainedValue()
                    .handle(pressed: pressed)
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(created, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(created, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            // Not permitted (0xe00002e2) until the TCC grant lands + relaunch.
            Log.error("caps_open_failed", category: .permission, code: Int(result))
            IOHIDManagerUnscheduleFromRunLoop(created, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            return false
        }
        manager = created
        Log.event("caps_hotkey_armed", category: .hotkey)
        return true
    }

    private func handle(pressed: Bool) {
        // Press-level breadcrumb (numeric only, invariant 4): the permission
        // QA needs to distinguish "events not arriving" from "pipeline dead".
        Log.event("caps_key", category: .hotkey, code: pressed ? 1 : 0)
        activation.apply(engine.handle(pressed ? .down : .up))
    }
}
