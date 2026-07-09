import SwiftUI
import KoeCore
import KoeStorage

/// History window content (plan M7-T2): reverse-chronological list with
/// full-text search, per-row copy / 👎 / delete, and delete-all. A pure
/// consumer of ``HistoryStore`` (search hybrid + FTS-consistent deletion are
/// the store's tested responsibilities).
struct HistoryView: View {
    @EnvironmentObject private var hub: SettingsHub
    @State private var records: [DictationRecord] = []
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var confirmDeleteAll = false
    /// Serializes competing reloads: five triggers can interleave (search
    /// edits vs FTS/LIKE latency differences), and a stale completion must
    /// not overwrite a newer one (review finding). MainActor-confined.
    @State private var reloadGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            if hub.historyStore == nil {
                ContentUnavailableView(
                    "履歴を利用できません",
                    systemImage: "exclamationmark.triangle",
                    description: Text("パイプライン初期化後に利用できます。")
                )
            } else {
                content
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        // Keyed on the refresh tick: reopening the cached window bumps it, so
        // dictations made while the window was closed appear (review finding).
        .task(id: hub.historyRefreshTick) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("履歴を検索", text: $query)
                .textFieldStyle(.plain)
                .onChange(of: query) { _, _ in Task { await reload() } }
        }
        .padding(8)
        Divider()

        if records.isEmpty {
            Spacer()
            Text(query.isEmpty ? "履歴はまだありません" : "「\(query)」に一致する履歴はありません")
                .foregroundStyle(.secondary)
            Spacer()
        } else {
            List(records, id: \.uuid) { record in
                row(record)
            }
            .listStyle(.inset)
        }

        Divider()
        HStack {
            Text("\(records.count) 件")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            // Only offered from the UNFILTERED view: deleteAll() is global,
            // and an empty search result must not invite wiping unseen rows
            // (review finding — data-loss class).
            Button("すべて削除…", role: .destructive) { confirmDeleteAll = true }
                .disabled(records.isEmpty || !query.isEmpty)
        }
        .padding(8)
        .confirmationDialog("履歴をすべて削除しますか？", isPresented: $confirmDeleteAll) {
            Button("すべて削除", role: .destructive) {
                Task {
                    try? await hub.historyStore?.deleteAll()
                    await reload()
                }
            }
        } message: {
            Text("すべての履歴（\(records.count) 件）を削除します。この操作は取り消せません。")
        }
    }

    @ViewBuilder
    private func row(_ record: DictationRecord) -> some View {
        let untranscribed = record.rawText.isEmpty && record.formattedText == nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(untranscribed ? "（未転写の録音 — 音声を文字にできませんでした）" : displayText(record))
                    .lineLimit(expanded.contains(record.uuid) ? nil : 2)
                    .foregroundStyle(untranscribed ? .secondary : .primary)
                Spacer(minLength: 8)
                badge(record, untranscribed: untranscribed)
            }
            if expanded.contains(record.uuid), record.formattedText != nil, !record.rawText.isEmpty {
                Text("認識結果: \(record.rawText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let app = record.appBundleID {
                    Text(app).lineLimit(1)
                }
                if record.degraded == true {
                    Text("整形なし").foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    copy(record)
                } label: { Image(systemName: "doc.on.doc") }
                    .help("コピー")
                Button {
                    toggleFeedback(record)
                } label: {
                    Image(systemName: record.feedback == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }
                    .help("結果が期待と違った（品質改善の指標になります）")
                Button(role: .destructive) {
                    delete(record)
                } label: { Image(systemName: "trash") }
                    .help("削除")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded.contains(record.uuid) {
                expanded.remove(record.uuid)
            } else {
                expanded.insert(record.uuid)
            }
        }
    }

    private func displayText(_ record: DictationRecord) -> String {
        let text = record.formattedText ?? record.rawText
        return text.isEmpty ? record.rawText : text
    }

    private func badge(_ record: DictationRecord, untranscribed: Bool) -> some View {
        let (label, color): (String, Color) = switch InsertResult(rawValue: record.insertResult ?? "") {
        case .pasted, .pastedViaAppleScript: ("挿入済み", .green)
        case .clipboardFallback: ("⌘V 待ち", .orange)
        case .blockedSecureInput: ("セキュア入力", .gray)
        case nil: (untranscribed ? "未転写" : "未挿入", .gray)
        }
        return Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: Actions

    private func reload() async {
        guard let store = hub.historyStore else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let result: [DictationRecord]
        if trimmed.isEmpty {
            result = (try? await store.recent(limit: 200)) ?? []
        } else {
            result = (try? await store.search(trimmed, limit: 200)) ?? []
        }
        // A newer reload started while this one was in flight — drop it.
        guard generation == reloadGeneration else { return }
        records = result
    }

    private func copy(_ record: DictationRecord) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(displayText(record), forType: .string)
    }

    private func toggleFeedback(_ record: DictationRecord) {
        guard let store = hub.historyStore, let uuid = UUID(uuidString: record.uuid) else { return }
        let next: Int? = record.feedback == -1 ? nil : -1
        Task {
            await store.updateFeedback(uuid, feedback: next)
            await reload()
        }
    }

    private func delete(_ record: DictationRecord) {
        guard let store = hub.historyStore, let uuid = UUID(uuidString: record.uuid) else { return }
        Task {
            try? await store.delete(uuid: uuid)
            await reload()
        }
    }
}
