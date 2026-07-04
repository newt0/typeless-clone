import ApplicationServices
// CGEvent predates Swift Concurrency and is not `Sendable`. The tap source is
// installed on the main run loop, so the callback always fires on the main
// thread and handing the event to the main actor is safe; `@preconcurrency`
// silences the (spurious here) cross-isolation Sendable diagnostics.
@preconcurrency import CoreGraphics
import KoeCore

/// CGEventTap runtime wrapper that drives a ``HotkeyEngine`` from the Fn key
/// (Design §7.3; plan M2-T1).
///
/// The testable activation logic lives in `HotkeyEngine`/`FnKey` (KoeCore); this
/// class is the thin, untestable adapter that owns the actual system event tap.
/// It listens on the session tap for `flagsChanged` (Fn arrives here, never as
/// key-down/up), decodes each event, and consumes the Fn events so the system
/// globe-key action is suppressed. Non-Fn events pass through untouched.
///
/// TCC: guarded by `AXIsProcessTrusted()`. The consuming tap + later synthetic
/// insertion + AX reads are all covered by Accessibility — Input Monitoring is
/// never requested (Design §7.7).
///
/// Liveness (`tapDisabled*` re-enable is stubbed here; the 60s verification
/// timer + revocation → ⚠︎ re-guidance is M2-T2).
@MainActor
final class FnHotkeyTap {
    private var engine: HotkeyEngine
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Invoked on recording start / stop. Called on the main run loop (the tap
    /// source is installed there), so UI updates need no extra hop.
    private let onStart: () -> Void
    private let onStop: () -> Void

    init(mode: HotkeyMode = .hold, onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.engine = HotkeyEngine(mode: mode)
        self.onStart = onStart
        self.onStop = onStop
    }

    /// Create and enable the tap. Returns `false` (without crashing) when
    /// Accessibility is not yet granted — the caller surfaces the ⚠︎ state.
    func start() -> Bool {
        guard AXIsProcessTrusted() else {
            Log.event("hotkey_ax_untrusted", category: .permission)
            return false
        }

        // M2-T1 only consumes the Fn key, which arrives as `flagsChanged`.
        // key-down/up (needed by the M2-T2 alt hotkey) are intentionally not
        // subscribed yet, so we don't route every system-wide keystroke through
        // this callback before anything uses them.
        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: fnHotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("hotkey_tap_create_failed", category: .hotkey)
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.event("hotkey_tap_started", category: .hotkey)
        return true
    }

    /// Disable and unregister the tap. Owned for the whole app lifetime by
    /// `AppDelegate`, so there is no `deinit` teardown — the single instance
    /// never outlives the process.
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        tap = nil
    }

    /// Called by the C trampoline (already hopped onto the main actor). Returns
    /// `nil` to consume the event, or the passed event to let it through.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Immediate self-heal so the tap does not silently die; the periodic
            // verification timer + revocation handling arrives in M2-T2.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A key-up during the disabled window is lost (the tap wasn't
            // listening), so the engine may be latched active — reset it (emits
            // .stop if so) to resync with the physical key rather than leaving
            // recording stuck on.
            dispatch(engine.reset())
            Log.event("hotkey_tap_reenabled", category: .hotkey)
            return nil

        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let fnActive = event.flags.contains(.maskSecondaryFn)
            guard let transition = FnKey.transition(keyCode: keyCode, secondaryFnActive: fnActive) else {
                // A different modifier (Shift/Cmd/…) — never Koe's business.
                return Unmanaged.passUnretained(event)
            }
            dispatch(engine.handle(transition))
            // Consume Fn to suppress the system globe-key action (Design §7.3).
            return nil

        default:
            // key-down/up flow through; the alt hotkey binding is M2-T2.
            return Unmanaged.passUnretained(event)
        }
    }

    private func dispatch(_ action: HotkeyAction) {
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

/// `@convention(c)` trampoline: recovers the `FnHotkeyTap` from `userInfo` and
/// forwards on the main actor (the tap source runs on the main run loop).
private func fnHotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let instance = Unmanaged<FnHotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { instance.handle(type: type, event: event) }
}
