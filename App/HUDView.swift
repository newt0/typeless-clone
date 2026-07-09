import SwiftUI
import KoeCore

/// Bridges the reducer-owned ``HUDModel`` into SwiftUI.
@MainActor
final class HUDModelStore: ObservableObject {
    @Published var model: HUDModel = .hidden
}

/// Pure projection of ``HUDModel`` (Design §7.5): a translucent capsule at the
/// bottom of the screen. No logic here — the reducer decides everything.
struct HUDView: View {
    @ObservedObject var store: HUDModelStore

    var body: some View {
        VStack(spacing: 4) {
            phaseLine
            if let notice = store.model.notice {
                Text(noticeText(notice))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(8)
        .fixedSize()
    }

    @ViewBuilder
    private var phaseLine: some View {
        switch store.model.phase {
        case .hidden:
            EmptyView()
        case .recording(let partial):
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text(partial.isEmpty ? "聞き取り中…" : partial)
                    .lineLimit(1)
                    .truncationMode(.head) // the newest words matter most
            }
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("整形中…")
            }
        case .done:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("挿入しました")
            }
        case .clipboardFallback:
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                Text("⌘V で貼り付けてください")
            }
        case .secureBlocked:
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text("セキュア入力中のため挿入しません")
            }
        case .failed:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text("音声を処理できませんでした")
            }
        }
    }

    private func noticeText(_ notice: HUDNotice) -> String {
        switch notice {
        case .deviceSwitched(let name):
            return "マイク切替: \(name)"
        case .capReached:
            return "録音上限（20分）に達しました"
        }
    }
}
