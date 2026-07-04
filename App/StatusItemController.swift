import AppKit
import KoeCore

/// Owns the menu-bar status item and its icon (Design §7.7).
///
/// The icon reflects app status (normal / recording / permission-warning); the
/// menu exposes History / Settings / Pause / Quit. History and Pause are
/// placeholders until M7 and the pause feature land.
@MainActor
final class StatusItemController {
    enum Status {
        case normal, recording, warning
    }

    private let statusItem: NSStatusItem
    private var status: Status = .normal

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyIcon()
        statusItem.menu = buildMenu()
    }

    func setStatus(_ status: Status) {
        self.status = status
        applyIcon()
    }

    private func applyIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        switch status {
        case .normal: symbol = "mic"
        case .recording: symbol = "mic.fill"
        case .warning: symbol = "exclamationmark.triangle"
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
        menu.addItem(.separator())

        let quit = menu.addItem(withTitle: "Quit Koe", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        return menu
    }

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
