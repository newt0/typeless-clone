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

    /// Push the edited per-app override table into the inserter.
    var applyOverrides: ((InsertionOverrideTable) -> Void)?
    /// Start/stop the Fn tap live.
    var applyFnEnabled: ((Bool) -> Void)?
}
