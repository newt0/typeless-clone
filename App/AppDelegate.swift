import AppKit
import KoeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var hotkeyTap: FnHotkeyTap?
    private var altHotkey: AltHotkeyMonitor?
    private var audioEngine: AudioCaptureEngine?
    private var drainTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app: no Dock icon, no app switcher (paired with LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        let statusItemController = StatusItemController()
        self.statusItemController = statusItemController
        Log.event("app_launched", category: .app)

        // Audio capture (M3-T1). Built prepared-but-stopped; the hotkey only
        // pays start(). Until the STT client is wired (M4), the produced chunk
        // stream is just drained so it can't build up — SessionAudioBuffer is
        // the retained copy for resend.
        let audioEngine = AudioCaptureEngine(
            onCapReached: { statusItemController.setRecording(false) }
        )
        self.audioEngine = audioEngine

        // Hotkey press starts recording and drains the chunk stream; release
        // stops it. Both hotkeys share this glue. The icon flips to "recording"
        // only once capture actually began — `start()` returns nil on failure
        // (e.g. mic TCC not granted) or when already recording, and in both
        // cases we leave the icon and the live drain task untouched (so a
        // second hotkey firing mid-hold can't orphan the running stream).
        let onStart: () -> Void = { [weak self] in
            guard let stream = audioEngine.start() else { return }
            statusItemController.setRecording(true)
            self?.drainTask?.cancel()
            self?.drainTask = Task { for await _ in stream {} }
        }
        let onStop: () -> Void = { [weak self] in
            statusItemController.setRecording(false)
            self?.audioEngine?.stop()
        }

        // Fn push-to-talk (CGEventTap). Its liveness monitor surfaces ⚠︎ if
        // Accessibility is later revoked.
        let tap = FnHotkeyTap(
            onStart: onStart,
            onStop: onStop,
            onRevoked: { statusItemController.setPermissionWarning(true) }
        )
        if !tap.start() {
            // Accessibility not granted yet: surface ⚠︎ instead of crashing.
            statusItemController.setPermissionWarning(true)
        }
        self.hotkeyTap = tap

        // Alternative hotkey (⌥Space, KeyboardShortcuts). Independent of the Fn
        // tap and of Accessibility, so it works even in the untrusted state.
        let alt = AltHotkeyMonitor(onStart: onStart, onStop: onStop)
        alt.start()
        self.altHotkey = alt
    }
}
