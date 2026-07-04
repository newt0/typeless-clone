import AppKit
import KoeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app: no Dock icon, no app switcher (paired with LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController()
        Log.event("app_launched", category: .app)
    }
}
