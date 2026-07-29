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
            StatsSettingsTab()
                .tabItem { Label("統計", systemImage: "chart.bar") }
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
    @State private var revertingLogin = false
    @State private var fnError = false
    @State private var revertingFn = false
    @State private var capsEnabled = AppSettings.capsLockHotkeyEnabled
    @State private var capsError = false
    @State private var revertingCaps = false

    var body: some View {
        Form {
            Section("ホットキー") {
                Toggle("Fn キー長押しで入力", isOn: $fnEnabled)
                    .onChange(of: fnEnabled) { previous, on in
                        guard !revertingFn else { revertingFn = false; return }
                        if hub.applyFnEnabled?(on) ?? false {
                            AppSettings.fnHotkeyEnabled = on
                            fnError = false
                        } else if on {
                            // Accessibility missing: revert visibly instead of
                            // showing an ON toggle for a dead hotkey.
                            fnError = true
                            revertingFn = true
                            fnEnabled = previous
                        }
                    }
                if fnError {
                    Text("アクセシビリティ権限がないため有効化できません。システム設定 > プライバシーとセキュリティ > アクセシビリティ で Koe を許可してください。")
                        .font(.caption).foregroundStyle(.red)
                }
                Toggle("Caps Lock 長押しで入力", isOn: $capsEnabled)
                    .onChange(of: capsEnabled) { previous, on in
                        guard !revertingCaps else { revertingCaps = false; return }
                        if hub.applyCapsEnabled?(on) ?? false {
                            AppSettings.capsLockHotkeyEnabled = on
                            capsError = false
                        } else if on {
                            // Input Monitoring missing: revert visibly instead
                            // of showing an ON toggle for a dead hotkey.
                            capsError = true
                            revertingCaps = true
                            capsEnabled = previous
                        }
                    }
                if capsError {
                    Text("「入力監視」の許可が必要です。システム設定 > プライバシーとセキュリティ > 入力監視 で Koe を許可し、アプリを再起動してからもう一度オンにしてください。")
                        .font(.caption).foregroundStyle(.red)
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
                        // A programmatic revert must not re-enter this handler
                        // and clear the error it just set (review finding).
                        guard !revertingLogin else { revertingLogin = false; return }
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginItemError = false
                        } catch {
                            Log.error("login_item_toggle_failed", category: .app)
                            loginItemError = true
                            let actual = SMAppService.mainApp.status == .enabled
                            if actual != on {
                                revertingLogin = true
                                launchAtLogin = actual
                            }
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
        // Keyed on pipeline readiness: the store opens asynchronously after
        // launch, and a one-shot .task that ran too early left the list empty
        // forever (review finding).
        .task(id: hub.pipelineReady) { await reload() }
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
    /// Presence probed once per appearance — a Keychain read is a securityd
    /// IPC and must not run on every keystroke (review finding).
    @State private var present: [SecretKey: Bool] = [:]

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
        .task {
            present[.speechmaticsAPIKey] = hub.secrets.read(.speechmaticsAPIKey) != nil
            present[.geminiAPIKey] = hub.secrets.read(.geminiAPIKey) != nil
        }
    }

    @ViewBuilder
    private func keyRow(key: SecretKey, text: Binding<String>) -> some View {
        let present = self.present[key] ?? false
        HStack {
            SecureField(present ? "設定済み（変更する場合のみ入力）" : "APIキーを入力", text: text)
            Button("保存") {
                let value = text.wrappedValue.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { return }
                if hub.secrets.write(value, for: key) {
                    text.wrappedValue = ""
                    self.present[key] = true
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


// MARK: - 統計 (M10-T2 — local-only, no body text)

private struct StatsSettingsTab: View {
    @EnvironmentObject private var hub: SettingsHub
    @State private var rows: [MetricsRow] = []
    @State private var feedback: (total: Int, down: Int) = (0, 0)
    @State private var redictation: Double?

    private struct Segment: Identifiable {
        let id: String
        let p50: Int?
        let p95: Int?
        let budgetP50: Int?
        let budgetP95: Int?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("直近 \(rows.count) 回のディクテーション（このMac内のみ・本文は記録されません）")
                .font(.caption).foregroundStyle(.secondary)
            Table(segments) {
                TableColumn("区間") { seg in Text(seg.id) }
                TableColumn("P50") { seg in
                    statText(seg.p50, budget: seg.budgetP50)
                }
                TableColumn("P95") { seg in
                    statText(seg.p95, budget: seg.budgetP95)
                }
                TableColumn("目標 (P50/P95)") { seg in
                    Text(seg.budgetP50.map { "\($0)ms / \(seg.budgetP95 ?? 0)ms" } ?? "—")
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 16) {
                let downRate = feedback.total > 0
                    ? Int((Double(feedback.down) / Double(feedback.total) * 100).rounded()) : 0
                Text("👎 率: \(downRate)%（\(feedback.down)/\(feedback.total)）")
                Text("30秒内の再発話率: \(redictation.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")")
            }
            .font(.caption)
            if AppSettings.telemetryOptOut {
                Text("利用統計の記録はオフです（一般タブで変更できます）。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding()
        .task(id: hub.pipelineReady) { await reload() }
    }

    private var segments: [Segment] {
        // Retry samples carry synthetic recording timestamps (stamped at
        // retry-click) — excluding them keeps the latency budget honest.
        let liveRows = rows.filter { !$0.isRetry }
        func stats(_ keyPath: KeyPath<MetricsRow, Int?>) -> (Int?, Int?) {
            let values = liveRows.compactMap { $0[keyPath: keyPath] }
            return (Percentiles.value(values, percentile: 50), Percentiles.value(values, percentile: 95))
        }
        let stt = stats(\.sttFinalizeMs)
        let llm = stats(\.llmMs)
        let ins = stats(\.insertionMs)
        let e2e = stats(\.endToEndMs)
        return [
            Segment(id: "STT確定（キー解放→確定）", p50: stt.0, p95: stt.1, budgetP50: nil, budgetP95: nil),
            Segment(id: "整形（確定→LLM完了）", p50: llm.0, p95: llm.1, budgetP50: nil, budgetP95: nil),
            Segment(id: "挿入（LLM完了→挿入）", p50: ins.0, p95: ins.1, budgetP50: nil, budgetP95: nil),
            Segment(id: "合計（キー解放→挿入）", p50: e2e.0, p95: e2e.1, budgetP50: 1500, budgetP95: 3000),
        ]
    }

    @ViewBuilder
    private func statText(_ value: Int?, budget: Int?) -> some View {
        if let value {
            Text("\(value)ms")
                .foregroundStyle(budget.map { value > $0 ? Color.red : .primary } ?? .primary)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private func reload() async {
        guard let metrics = hub.metricsStore else { return }
        rows = (try? await metrics.recent(limit: 100)) ?? []
        redictation = MetricsStore.redictationRate(rows: rows)
        if let history = hub.historyStore {
            feedback = (try? await history.feedbackStats()) ?? (0, 0)
        }
    }
}
