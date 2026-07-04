import AppKit
import KoeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var hotkeyTap: FnHotkeyTap?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app: no Dock icon, no app switcher (paired with LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        let statusItemController = StatusItemController()
        self.statusItemController = statusItemController
        Log.event("app_launched", category: .app)

        // Fn push-to-talk. Until the dictation session is wired (M3/M5), the
        // hotkey just flips the menu-bar icon so the press/release path is
        // observable during QA.
        let tap = FnHotkeyTap(
            onStart: { statusItemController.setStatus(.recording) },
            onStop: { statusItemController.setStatus(.normal) }
        )
        if !tap.start() {
            // Accessibility not granted yet: surface ⚠︎ instead of crashing.
            statusItemController.setStatus(.warning)
        }
        self.hotkeyTap = tap
    }
}
