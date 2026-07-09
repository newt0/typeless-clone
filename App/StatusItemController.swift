import AppKit
import KoeCore

/// Owns the menu-bar status item and its icon (Design §7.7).
///
/// The icon reflects app status (normal / recording / permission-warning); the
/// menu exposes History / Settings / Pause / Quit. History and Pause are
/// placeholders until M7 and the pause feature land.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    /// Transient: true only while a dictation is being recorded.
    private var recording = false
    /// Latched: a permission problem (Accessibility not granted / revoked) that
    /// persists across recording toggles. Kept separate from `recording` so a
    /// working alt hotkey can't silently clear the ⚠︎ for a dead Fn path.
    private var permissionWarning = false
    /// Latched: the pipeline could not be assembled (missing Speechmatics key,
    /// history DB failed to open). Same ⚠︎ as `permissionWarning` but its own
    /// flag + log event so the causes stay distinguishable in Console.
    private var configurationWarning = false

    /// DEBUG-only QA actions: delayed pastes so the owner can exercise each
    /// insertion path (M5-T2/T3) before the STT→format→paste pipeline is wired
    /// end-to-end. Each entry becomes a menu item.
    private let qaActions: [(title: String, run: () -> Void)]

    init(qaActions: [(title: String, run: () -> Void)] = []) {
        self.qaActions = qaActions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyIcon()
        statusItem.menu = buildMenu()
    }

    func setRecording(_ active: Bool) {
        recording = active
        applyIcon()
    }

    func setPermissionWarning(_ on: Bool) {
        permissionWarning = on
        applyIcon()
    }

    func setConfigurationWarning(_ on: Bool) {
        configurationWarning = on
        applyIcon()
    }

    private func applyIcon() {
        guard let button = statusItem.button else { return }
        // Recording is the transient overlay; the latched ⚠︎ shows through again
        // as soon as recording stops (permission > configuration > normal).
        let symbol: String
        if recording {
            symbol = "mic.fill"
        } else if permissionWarning || configurationWarning {
            symbol = "exclamationmark.triangle"
        } else {
            symbol = "mic"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Koe")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "History…", action: nil, keyEquivalent: "") // placeholder (M7)

        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self

        menu.addItem(.separator())
        menu.addItem(withTitle: "Pause", action: nil, keyEquivalent: "") // placeholder

        #if DEBUG
        if !qaActions.isEmpty {
            menu.addItem(.separator())
            for (index, action) in qaActions.enumerated() {
                let item = menu.addItem(
                    withTitle: action.title,
                    action: #selector(runQAAction(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = index
            }
        }
        #endif

        menu.addItem(.separator())

        let quit = menu.addItem(withTitle: "Quit Koe", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        return menu
    }

    #if DEBUG
    @objc private func runQAAction(_ sender: NSMenuItem) {
        guard qaActions.indices.contains(sender.tag) else { return }
        qaActions[sender.tag].run()
    }
    #endif

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // Open the SwiftUI Settings scene (selector name is macOS 14+).
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() {
        Log.event("app_quit", category: .app)
        NSApp.terminate(nil)
    }
}
