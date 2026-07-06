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

    /// DEBUG-only QA action: triggers a delayed paste so the owner can verify
    /// path 1 (M5-T2) before the STT→format→paste pipeline is wired end-to-end.
    private let onTestPaste: (() -> Void)?

    init(onTestPaste: (() -> Void)? = nil) {
        self.onTestPaste = onTestPaste
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

    private func applyIcon() {
        guard let button = statusItem.button else { return }
        // Recording is the transient overlay; the latched ⚠︎ shows through again
        // as soon as recording stops.
        let symbol: String
        if recording {
            symbol = "mic.fill"
        } else if permissionWarning {
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
        if onTestPaste != nil {
            let test = menu.addItem(
                withTitle: "Insert Test Text (QA, 2s delay)",
                action: #selector(runTestPaste),
                keyEquivalent: ""
            )
            test.target = self
        }
        #endif

        menu.addItem(.separator())

        let quit = menu.addItem(withTitle: "Quit Koe", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        return menu
    }

    #if DEBUG
    @objc private func runTestPaste() {
        onTestPaste?()
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
