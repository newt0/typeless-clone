import AppKit
import KoeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var hotkeyTap: FnHotkeyTap?
    private var altHotkey: AltHotkeyMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app: no Dock icon, no app switcher (paired with LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        let statusItemController = StatusItemController()
        self.statusItemController = statusItemController
        Log.event("app_launched", category: .app)

        // Until the dictation session is wired (M3/M5), the hotkeys just flip the
        // menu-bar icon so the press/release path is observable during QA.
        let onStart = { statusItemController.setRecording(true) }
        let onStop = { statusItemController.setRecording(false) }

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
