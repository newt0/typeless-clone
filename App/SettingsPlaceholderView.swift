import SwiftUI

/// Placeholder preferences window. Real settings (hotkey, style, dictionary,
/// history, per-app overrides) arrive in M10.
struct SettingsPlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Koe")
                .font(.title2).bold()
            Text("Settings will appear here — hotkey, writing style, personal dictionary, history, and per-app overrides.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 420, height: 180, alignment: .topLeading)
    }
}
