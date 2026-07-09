import SwiftUI

/// Menu-bar agent entry point (Design §3, §7.7). The app has no main window; an
/// `AppDelegate` sets the accessory activation policy and owns the status item.
/// The `Settings` scene hosts the M10 preferences window.
@main
struct KoeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(delegate.settingsHub)
        }
    }
}
