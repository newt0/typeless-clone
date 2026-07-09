import SwiftUI
import ServiceManagement
import KeyboardShortcuts
import KoeCore
import KoeStorage

/// Preferences window (plan M10-T1): every control writes through
/// ``AppSettings`` (UserDefaults) or the Keychain, and its owning module reads
/// the value live — closing the window is never required for a setting to
/// take effect. API keys never touch UserDefaults (invariant 5).
struct SettingsView: View {
    @EnvironmentObject private var hub: SettingsHub

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("一般", systemImage: "gearshape") }
            DictionarySettingsTab()
                .tabItem { Label("辞書", systemImage: "character.book.closed") }
            OverridesSettingsTab()
                .tabItem { Label("アプリ別", systemImage: "square.grid.2x2") }
            APIKeysSettingsTab()
                .tabItem { Label("APIキー", systemImage: "key") }
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - 一般

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var hub: SettingsHub
    @State private var style = AppSettings.writingStyle
    @State private var preferBuiltIn = AppSettings.preferBuiltInMic
    @State private var degradedToClipboard = AppSettings.degradedToClipboard
    @State private var fnEnabled = AppSettings.fnHotkeyEnabled
    @State private var retentionDays = AppSettings.historyRetentionDays
    @State private var telemetryOptOut = AppSettings.telemetryOptOut
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError = false

    var body: some View {
        Form {
            Section("ホットキー") {
                Toggle("Fn キー長押しで入力", isOn: $fnEnabled)
                    .onChange(of: fnEnabled) { _, on in
                        AppSettings.fnHotkeyEnabled = on
                        hub.applyFnEnabled?(on)
                    }
                KeyboardShortcuts.Recorder("代替ホットキー（押している間入力）:", name: .dictation)
            }
            Section("整形") {
                Picker("文体", selection: $style) {
                    Text("自動（混在はですます統一）").tag(WritingStyle.auto)
                    Text("ですます調").tag(WritingStyle.desuMasu)
                    Text("である調").tag(WritingStyle.dearu)
                }
                .onChange(of: style) { _, value in AppSettings.writingStyle = value }
                Toggle("整形失敗時はクリップボードに残す（既定: そのまま挿入）", isOn: $degradedToClipboard)
                    .onChange(of: degradedToClipboard) { _, on in AppSettings.degradedToClipboard = on }
            }
            Section("マイク") {
                Toggle("内蔵マイクを優先（Bluetooth の低音質を回避）", isOn: $preferBuiltIn)
                    .onChange(of: preferBuiltIn) { _, on in AppSettings.preferBuiltInMic = on }
            }
            Section("履歴・その他") {
                Picker("履歴の自動削除", selection: $retentionDays) {
                    Text("しない").tag(0)
                    Text("7日後").tag(7)
                    Text("30日後").tag(30)
                    Text("90日後").tag(90)
                }
                .onChange(of: retentionDays) { _, days in
                    AppSettings.historyRetentionDays = days
                    if days > 0, let history = hub.historyStore {
                        Task { try? await history.deleteOlderThan(days: days) }
                    }
                }
                Toggle("利用統計（ローカルのみ）を記録しない", isOn: $telemetryOptOut)
                    .onChange(of: telemetryOptOut) { _, on in AppSettings.telemetryOptOut = on }
                Toggle("ログイン時に起動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginItemError = false
                        } catch {
                            Log.error("login_item_toggle_failed", category: .app)
                            loginItemError = true
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if loginItemError {
                    Text("ログイン項目を変更できませんでした。システム設定 > 一般 > ログイン項目 から変更してください。")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 辞書 (M8-T1 store editor)

private struct DictionarySettingsTab: View {
    @EnvironmentObject private var hub: SettingsHub
    @State private var terms: [DictionaryTerm] = []
    @State private var newSurface = ""
    @State private var newReading = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hub.dictionaryStore == nil {
                ContentUnavailableView(
                    "辞書を利用できません",
                    systemImage: "exclamationmark.triangle",
                    description: Text("パイプライン初期化後に利用できます（APIキー/ストアを確認）。")
                )
            } else {
                Text("固有名詞や専門用語を登録すると、音声認識と整形の両方に反映されます。")
                    .font(.caption).foregroundStyle(.secondary)
                Table(terms) {
                    TableColumn("表記") { term in Text(term.surface) }
                    TableColumn("読み（任意）") { term in Text(term.reading ?? "") }
                    TableColumn("") { term in
                        Button(role: .destructive) {
                            delete(term)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                    .width(28)
                }
                HStack {
                    TextField("表記（例: Koe）", text: $newSurface)
                    TextField("読み（例: こえ）", text: $newReading)
                    Button("追加") { add() }
                        .disabled(newSurface.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding()
        .task { await reload() }
    }

    private func reload() async {
        guard let store = hub.dictionaryStore else { return }
        terms = (try? await store.all()) ?? []
    }

    private func add() {
        guard let store = hub.dictionaryStore else { return }
        let surface = newSurface.trimmingCharacters(in: .whitespaces)
        let reading = newReading.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                _ = try await store.add(surface: surface, reading: reading.isEmpty ? nil : reading)
                newSurface = ""
                newReading = ""
                errorText = nil
            } catch {
                errorText = "追加できませんでした（同じ表記が登録済みの可能性）。"
            }
            await reload()
        }
    }

    private func delete(_ term: DictionaryTerm) {
        guard let store = hub.dictionaryStore, let id = term.id else { return }
        Task {
            try? await store.delete(id: id)
            await reload()
        }
    }
}

// MARK: - アプリ別 (M5-T3 override table editor)

private struct OverridesSettingsTab: View {
    @EnvironmentObject private var hub: SettingsHub
    @State private var entries = AppSettings.overrideEntries
    @State private var newBundleID = ""
    @State private var newPath = InsertionPath.paste
    @State private var newDelayMS = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("貼り付けがうまく動かないアプリには、挿入経路や貼り付け前の待ち時間を個別に指定できます。")
                .font(.caption).foregroundStyle(.secondary)
            Table(entries) {
                TableColumn("Bundle ID") { entry in Text(entry.bundleID) }
                TableColumn("経路") { entry in Text(pathLabel(entry.path)) }
                TableColumn("追加待機") { entry in Text("\(entry.extraDelayMS)ms") }
                TableColumn("") { entry in
                    Button(role: .destructive) {
                        entries.removeAll { $0.bundleID == entry.bundleID }
                        persist()
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                }
                .width(28)
            }
            HStack {
                TextField("Bundle ID（例: com.tinyspeck.slackmacgap）", text: $newBundleID)
                Picker("", selection: $newPath) {
                    ForEach(InsertionPath.allCases, id: \.self) { Text(pathLabel($0.rawValue)).tag($0) }
                }
                .frame(width: 170)
                Picker("", selection: $newDelayMS) {
                    Text("+0ms").tag(0)
                    Text("+100ms").tag(100)
                    Text("+300ms").tag(300)
                }
                .frame(width: 100)
                Button("追加") {
                    let bundleID = newBundleID.trimmingCharacters(in: .whitespaces)
                    guard !bundleID.isEmpty else { return }
                    entries.removeAll { $0.bundleID == bundleID }
                    entries.append(.init(bundleID: bundleID, path: newPath.rawValue, extraDelayMS: newDelayMS))
                    newBundleID = ""
                    persist()
                }
                .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
    }

    private func persist() {
        AppSettings.overrideEntries = entries
        hub.applyOverrides?(AppSettings.overrideTable())
    }

    private func pathLabel(_ raw: String) -> String {
        switch InsertionPath(rawValue: raw) {
        case .paste: return "通常（⌘V 送出）"
        case .appleScript: return "AppleScript"
        case .clipboardOnly: return "クリップボードのみ"
        case nil: return raw
        }
    }
}

// MARK: - API キー (Keychain only — invariant 5)

private struct APIKeysSettingsTab: View {
    @EnvironmentObject private var hub: SettingsHub
    @State private var speechmaticsKey = ""
    @State private var geminiKey = ""
    @State private var savedNote: String?

    var body: some View {
        Form {
            Section {
                Text("キーは Keychain のみに保存されます（UserDefaults やファイルには書き込みません）。変更後はアプリを再起動してください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speechmatics（音声認識・必須）") {
                keyRow(key: .speechmaticsAPIKey, text: $speechmaticsKey)
            }
            Section("Gemini（整形・未設定時は無整形で挿入）") {
                keyRow(key: .geminiAPIKey, text: $geminiKey)
            }
            if let savedNote {
                Text(savedNote).font(.caption).foregroundStyle(.green)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func keyRow(key: SecretKey, text: Binding<String>) -> some View {
        let present = hub.secrets.read(key) != nil
        HStack {
            SecureField(present ? "設定済み（変更する場合のみ入力）" : "APIキーを入力", text: text)
            Button("保存") {
                let value = text.wrappedValue.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { return }
                if hub.secrets.write(value, for: key) {
                    text.wrappedValue = ""
                    savedNote = "保存しました。反映にはアプリの再起動が必要です。"
                    Log.event("api_key_saved", category: .app)
                } else {
                    savedNote = "保存に失敗しました。"
                }
            }
            .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
