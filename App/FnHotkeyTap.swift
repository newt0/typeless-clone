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
/// Liveness (plan M2-T2): the callback re-enables the tap immediately on
/// `tapDisabled*`; additionally a periodic check (``KoeConstants/tapLivenessInterval``)
/// re-enables a silently-disabled tap and detects Accessibility revocation,
/// tearing the tap down and firing ``onRevoked`` so the caller shows ⚠︎ +
/// re-guidance (M11 refines the re-arm flow).
@MainActor
final class FnHotkeyTap {
    private var engine: HotkeyEngine
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var livenessTask: Task<Void, Never>?

    /// Recording start/stop glue, shared with ``AltHotkeyMonitor``. Fired on the
    /// main run loop (the tap source is installed there), so UI needs no hop.
    private let activation: HotkeyActivation
    /// Invoked when the liveness check finds Accessibility was revoked (the tap
    /// is torn down first). The caller surfaces the ⚠︎ warning state.
    private let onRevoked: () -> Void

    init(
        mode: HotkeyMode = .hold,
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onRevoked: @escaping () -> Void = {}
    ) {
        self.engine = HotkeyEngine(mode: mode)
        self.activation = HotkeyActivation(onStart: onStart, onStop: onStop)
        self.onRevoked = onRevoked
    }

    /// Create and enable the tap. Returns `false` (without crashing) when
    /// Accessibility is not yet granted — the caller surfaces the ⚠︎ state.
    func start() -> Bool {
        guard AXIsProcessTrusted() else {
            Log.event("hotkey_ax_untrusted", category: .permission)
            return false
        }

        // This tap only ever handles the Fn key, which arrives as `flagsChanged`
        // — so it subscribes to nothing else and doesn't route every system-wide
        // keystroke through this callback. (The Fn-alternative hotkey is a
        // wholly separate KeyboardShortcuts path in `AltHotkeyMonitor`, not an
        // expansion of this mask.)
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
        startLivenessMonitor()
        Log.event("hotkey_tap_started", category: .hotkey)
        return true
    }

    /// Turn the hotkey off from Settings (M10). Unlike a bare ``stop()``, this
    /// first resets the engine THROUGH the activation, so a recording that is
    /// mid-hold gets its `onStop` (icon reset + mic stop) — with the tap gone,
    /// the physical key-up could never deliver it (review finding: the mic
    /// stayed recording until the 20-minute cap).
    func disable() {
        activation.apply(engine.reset())
        stop()
        Log.event("hotkey_tap_disabled", category: .hotkey)
    }

    /// Disable and unregister the tap. Owned for the whole app lifetime by
    /// `AppDelegate`, so there is no `deinit` teardown — the single instance
    /// never outlives the process.
    func stop() {
        livenessTask?.cancel()
        livenessTask = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        tap = nil
    }

    // MARK: Liveness

    /// Poll tap validity + Accessibility on an interval. A `Task` (not a
    /// `Timer`) so the loop inherits this actor's isolation — `Timer`'s
    /// `@Sendable` block can't capture the `@MainActor` `self`.
    private func startLivenessMonitor() {
        livenessTask?.cancel()
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: KoeConstants.tapLivenessInterval)
                guard !Task.isCancelled, let self else { return }
                self.checkLiveness()
            }
        }
    }

    private func checkLiveness() {
        let enabled = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        switch TapLiveness.evaluate(trusted: AXIsProcessTrusted(), tapEnabled: enabled) {
        case .healthy:
            break
        case .needsReenable:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Events (incl. a Fn key-up) were dropped while disabled, so the
            // engine may be latched active — resync like the callback path does.
            activation.apply(engine.reset())
            Log.event("hotkey_tap_reenabled", category: .hotkey)
        case .revoked:
            // Drop any in-flight recording, tear down, and let the caller warn.
            Log.event("hotkey_ax_revoked", category: .permission)
            activation.apply(engine.reset())
            stop()
            onRevoked()
        }
    }

    /// Called by the C trampoline (already hopped onto the main actor). Returns
    /// `nil` to consume the event, or the passed event to let it through.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Immediate self-heal so the tap does not silently die (the periodic
            // liveness check is the backstop for disables we never see here).
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A key-up during the disabled window is lost (the tap wasn't
            // listening), so the engine may be latched active — reset it (emits
            // .stop if so) to resync with the physical key rather than leaving
            // recording stuck on.
            activation.apply(engine.reset())
            Log.event("hotkey_tap_reenabled", category: .hotkey)
            return nil

        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let fnActive = event.flags.contains(.maskSecondaryFn)
            guard let transition = FnKey.transition(keyCode: keyCode, secondaryFnActive: fnActive) else {
                // A different modifier (Shift/Cmd/…) — never Koe's business.
                return Unmanaged.passUnretained(event)
            }
            activation.apply(engine.handle(transition))
            // Consume Fn to suppress the system globe-key action (Design §7.3).
            return nil

        default:
            // The mask only requests flagsChanged; anything else is unexpected —
            // pass it through untouched.
            return Unmanaged.passUnretained(event)
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
