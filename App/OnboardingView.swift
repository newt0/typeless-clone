import SwiftUI
import AVFoundation
import ApplicationServices
import ServiceManagement
import KeyboardShortcuts
import KoeCore

/// First-run onboarding (plan M11-T1; Design §11.2): six steps to a working
/// dictation in ≤3 minutes. Every step is skippable (the app shows ⚠︎ without
/// steps 2–3); re-runnable from the status menu. Permission checks poll so
/// grants made in System Settings auto-advance the flow.
struct OnboardingView: View {
    @EnvironmentObject private var hub: SettingsHub
    @State private var step = 0
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var tapArmFailed = false
    @State private var testText = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let stepTitles = ["ようこそ", "マイク", "アクセシビリティ", "ホットキー", "テスト入力", "完了"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(stepTitles.indices, id: \.self) { index in
                    Circle()
                        .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
                Spacer()
                Text("\(step + 1)/\(stepTitles.count) \(stepTitles[step])")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Group {
                switch step {
                case 0: welcome
                case 1: microphone
                case 2: accessibility
                case 3: hotkey
                case 4: testDictation
                default: finish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if step > 0 {
                    Button("戻る") { step -= 1 }
                }
                Spacer()
                if step < 5 {
                    Button("スキップ") { advance() }
                        .buttonStyle(.borderless)
                    Button(step == 0 ? "同意して開始" : "次へ") { advance() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("完了") {
                        AppSettings.onboardingCompleted = true
                        Log.event("onboarding_completed", category: .app)
                        NSApp.keyWindow?.close()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
        .task(id: step) { await pollPermissions() }
    }

    private func advance() { step = min(step + 1, 5) }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Koe — 押して話すだけの日本語音声入力").font(.title2).bold()
            Text("""
            キーを押しながら話すと、認識・整形されたテキストがカーソル位置に入力されます。

            プライバシーについて（ご同意のうえお進みください）:
            • 音声は文字起こしのため Speechmatics（英国/EU リージョン）へ、テキストは整形のため Google Gemini（米国）へ送信されます。
            • どちらのプロバイダでも入力内容が AI の学習に使われない設定/契約で利用します。
            • 履歴はこの Mac の中にのみ保存されます。外部への送信は上記 2 社のみです。
            • 統計情報（所要時間など、本文を含まない数値）もこの Mac 内にのみ記録されます。
            """)
            .font(.callout)
        }
    }

    private var microphone: some View {
        permissionStep(
            granted: micGranted,
            title: "マイクへのアクセス",
            body: "音声入力にはマイクが必要です。「許可を求める」を押すと macOS のダイアログが表示されます。",
            requestLabel: "許可を求める",
            request: {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in micGranted = granted }
                }
            },
            settingsPane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 10) {
            permissionStep(
                granted: axTrusted,
                title: "アクセシビリティ（最重要）",
                body: "Fn ホットキーの検知とテキスト挿入（⌘V 送出）に必要です。「許可を求める」→ ダイアログの「システム設定を開く」→ Koe を ON にしてください。許可されると自動で次に進みます。",
                requestLabel: "許可を求める",
                request: {
                    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                },
                settingsPane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
            if tapArmFailed {
                Text("権限は付与されましたが、ホットキーの有効化に失敗しました。アプリを再起動すると解消されます（macOS の既知の挙動）。")
                    .font(.callout).foregroundStyle(.orange)
                Button("再起動して続行") { relaunch() }
            }
        }
    }

    private var hotkey: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ホットキー").font(.title3).bold()
            Text("""
            既定は **Fn（🌐）キーの長押し** です。押している間だけ録音されます。

            ⚠️ macOS 標準の「🌐 を 2 回押して音声入力」と競合するため、
            システム設定 > キーボード の「🌐 キーを押して」を **「何もしない」** にすることをおすすめします。
            """)
            Button("キーボード設定を開く") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
            }
            Divider()
            Text("Fn が使えない/使いたくない場合の代替ホットキー（押している間入力）:")
                .font(.callout)
            KeyboardShortcuts.Recorder("代替ホットキー:", name: .dictation)
        }
    }

    private var testDictation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("テスト入力").font(.title3).bold()
            Text("下の欄をクリックしてカーソルを置き、ホットキー（Fn または ⌥Space）を押しながら一言話して、離してください。")
                .font(.callout)
            TextField("ここに結果が入力されます", text: $testText, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
            if !testText.isEmpty {
                Label("成功！認識・整形・挿入のすべてが動いています。", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if !hub.pipelineReady {
                Text("パイプライン初期化中です。API キーが未設定の場合は設定 > APIキー から登録してください。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("セットアップ完了").font(.title3).bold()
            Text("""
            メニューバーのマイクアイコンから 履歴（⌘Y）/ 設定（⌘,）/ 終了 にアクセスできます。
            ⚠︎ が表示されている場合は権限に問題があります（クリックで確認）。
            このセットアップはメニューの「セットアップをやり直す」からいつでも再実行できます。
            """)
            .font(.callout)
            Toggle("ログイン時に Koe を起動", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func permissionStep(
        granted: Bool,
        title: String,
        body: String,
        requestLabel: String,
        request: @escaping () -> Void,
        settingsPane: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3).bold()
                if granted {
                    Label("許可済み", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            Text(body).font(.callout)
            if !granted {
                HStack {
                    Button(requestLabel, action: request)
                    Button("システム設定を開く") {
                        NSWorkspace.shared.open(URL(string: settingsPane)!)
                    }
                }
            }
        }
    }

    /// Poll every 2s while a permission step is showing: grants made in
    /// System Settings auto-advance (§11.2 step 3), and the AX grant is
    /// followed by an immediate tap-arm attempt to catch the known
    /// post-grant failure quirk.
    private func pollPermissions() async {
        while !Task.isCancelled {
            switch step {
            case 1:
                micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                if micGranted { advance(); return }
            case 2:
                let trusted = AXIsProcessTrusted()
                if trusted, !axTrusted {
                    axTrusted = true
                    if hub.applyFnEnabled?(AppSettings.fnHotkeyEnabled) == false {
                        tapArmFailed = true
                        Log.error("onboarding_tap_arm_failed", category: .permission)
                        return // stay on this step; offer the relaunch path
                    }
                    advance()
                    return
                }
                axTrusted = trusted
            default:
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
