import Foundation
import KoeCore
import KoeStorage

/// Bridges the composition root's live objects into the Settings scene
/// (plan M10-T1). `AppDelegate` fills it as the pipeline assembles; the
/// SwiftUI views read it via `@EnvironmentObject`. All appliers run on the
/// main actor and take effect on the next dictation — no relaunch.
@MainActor
final class SettingsHub: ObservableObject {
    /// Secret storage for the API-key tab (invariant 5: Keychain only).
    let secrets: any SecretStore = KeychainSecretStore()

    /// nil until the pipeline assembled (stores unavailable → tabs explain).
    @Published var dictionaryStore: DictionaryStore?
    @Published var historyStore: HistoryStore?
    @Published var pipelineReady = false
    /// Bumped when the History window (re)opens and when the pipeline becomes
    /// ready — the view's `.task(id:)` reload key.
    @Published var historyRefreshTick = 0

    /// Push the edited per-app override table into the inserter.
    var applyOverrides: ((InsertionOverrideTable) -> Void)?
    /// Start/stop the Fn tap live; returns whether the change took effect
    /// (false = Accessibility missing — the toggle reverts).
    var applyFnEnabled: ((Bool) -> Bool)?
}
