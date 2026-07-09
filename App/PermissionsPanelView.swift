import SwiftUI
import AVFoundation
import ApplicationServices
import KoeCore

/// "What's broken and how to fix it" panel (plan M11-T2; Design §11.3).
/// Reached from the status menu's warning item and from a hotkey press that
/// can't start — the hotkey must never appear simply dead. Pure status
/// readout + one-click deep links; the Fn re-arm itself is automatic
/// (`FnHotkeyTap` re-grant watcher).
struct PermissionsPanelView: View {
    @EnvironmentObject private var hub: SettingsHub
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var sttKeyPresent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Koe の動作状態").font(.title3).bold()

            statusRow(
                ok: micStatus == .authorized,
                title: "マイク",
                detail: micStatus == .authorized ? "許可済み" : "未許可 — 録音できません",
                fixLabel: "システム設定を開く",
                fix: { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
            )
            statusRow(
                ok: axTrusted,
                title: "アクセシビリティ",
                detail: axTrusted
                    ? "許可済み — 許可直後に Fn が反応しない場合はアプリを再起動してください"
                    : "未許可 — Fn ホットキーとテキスト挿入が動きません",
                fixLabel: "システム設定を開く",
                fix: { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
            )
            statusRow(
                ok: sttKeyPresent,
                title: "Speechmatics API キー",
                detail: sttKeyPresent ? "設定済み" : "未設定 — 音声認識できません",
                fixLabel: "設定を開く",
                fix: { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            )

            HStack {
                Spacer()
                Button("再チェック") { Task { await refresh() } }
            }
            Text("権限を付与すると（アクセシビリティは最大 5 秒で）自動的に復帰します。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 480)
        .task { await refresh() }
    }

    @ViewBuilder
    private func statusRow(ok: Bool, title: String, detail: String, fixLabel: String, fix: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok {
                Button(fixLabel, action: fix)
            }
        }
    }

    private func refresh() async {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        axTrusted = AXIsProcessTrusted()
        // Off the main actor: a securityd stall / consent dialog on this read
        // must not freeze the menu and hotkeys (review finding — same
        // rationale as assemblePipeline's detached reads).
        let secrets = hub.secrets
        sttKeyPresent = await Task.detached { secrets.read(.speechmaticsAPIKey) != nil }.value
        if axTrusted {
            // Opportunistic re-arm — safe now: start() is a no-op on a
            // healthy tap, so this cannot cut off a live dictation.
            let armed = hub.applyFnEnabled?(AppSettings.fnHotkeyEnabled) ?? true
            if armed, micStatus == .authorized {
                // Everything actionable is green: release the latched ⚠︎
                // (mic-caused warnings had no other clearing path — review
                // finding).
                hub.setPermissionWarning?(false)
            }
        }
    }

    private func open(_ url: String) {
        NSWorkspace.shared.open(URL(string: url)!)
    }
}
