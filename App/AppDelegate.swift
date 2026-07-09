import AppKit
import KoeCore
import KoeProviders
import KoeStorage

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var hotkeyTap: FnHotkeyTap?
    private var altHotkey: AltHotkeyMonitor?
    private var audioEngine: AudioCaptureEngine?
    private var pasteSimulator: PasteSimulator?
    private var audioSource: HotkeyAudioSource?
    private var coordinator: SessionCoordinator?
    private var historyStore: HistoryStore?
    private var dictionaryStore: DictionaryStore?
    private var pressLoopTask: Task<Void, Never>?
    private var pressContinuation: AsyncStream<Void>.Continuation?
    private var hudController: HUDPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app: no Dock icon, no app switcher (paired with LSUIElement).
        NSApp.setActivationPolicy(.accessory)

        // One AX/frontmost reader shared by the inserter (preflight/verify) and
        // the coordinator (per-utterance recording-app capture).
        let contextProvider = InsertionContextProvider()
        let pasteSimulator = PasteSimulator(context: contextProvider)
        self.pasteSimulator = pasteSimulator

        // DEBUG QA hooks (M5-T2/T3): delayed test pastes that exercise each
        // insertion path by hand, independent of the live pipeline. Click a
        // menu item, then focus a target field within 2s.
        #if DEBUG
        let sample = "Koe paste test — こんにちは、世界。"
        func scheduledPaste(_ label: StaticString, _ body: @escaping @MainActor () async -> Void) -> () -> Void {
            {
                Log.event(label, category: .insertion)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    await body()
                }
            }
        }
        let qaActions: [(title: String, run: () -> Void)] = [
            ("QA: Insert Test Text — Path 1 (paste, 2s)", scheduledPaste("qa_paste_path1") {
                _ = await pasteSimulator.debugInsert(sample, forcing: .paste)
            }),
            ("QA: Insert Test Text — Path 2 (AppleScript, 2s)", scheduledPaste("qa_paste_path2") {
                _ = await pasteSimulator.debugInsert(sample, forcing: .appleScript)
            }),
            ("QA: Insert Test Text — Path 3 (clipboard only, 2s)", scheduledPaste("qa_paste_path3") {
                _ = await pasteSimulator.debugInsert(sample, forcing: .clipboardOnly)
            }),
        ]
        #else
        let qaActions: [(title: String, run: () -> Void)] = []
        #endif
        let statusItemController = StatusItemController(qaActions: qaActions)
        self.statusItemController = statusItemController
        Log.event("app_launched", category: .app)

        // HUD panel (M9-T1): renders the pipeline lifecycle + engine notices.
        let hud = HUDPanelController()
        self.hudController = hud

        // Audio capture (M3-T1/M3-T2). "Prefer built-in mic" defaults ON; the
        // closure is re-read each start so a future Settings toggle takes
        // effect without rebuilding the engine. Cap → notice; fault → icon
        // reset only (the failure reaches the HUD through the pipeline).
        let audioEngine = AudioCaptureEngine(
            preferBuiltIn: { UserDefaults.standard.object(forKey: AppDefaultsKey.preferBuiltInMic) as? Bool ?? true },
            onCapReached: {
                statusItemController.setRecording(false)
                hud.notify(.capReached)
            },
            onCaptureFault: { statusItemController.setRecording(false) },
            onDeviceSwitched: { device in hud.notify(.deviceSwitched(name: device.name)) }
        )
        self.audioEngine = audioEngine

        let audioSource = HotkeyAudioSource()
        self.audioSource = audioSource

        // Press queue: a single consumer awaits each startUtterance() before
        // taking the next press, which is what maps press order onto FIFO
        // ticket order (batch-B contract in SessionCoordinator.startUtterance).
        // The hotkey callback itself only yields — never blocks the main actor.
        let (presses, pressContinuation) = AsyncStream<Void>.makeStream()
        self.pressContinuation = pressContinuation
        pressLoopTask = Task { [weak self] in
            for await _ in presses {
                guard let coordinator = self?.coordinator else { continue }
                await coordinator.startUtterance()
            }
        }

        // Hotkey press starts recording and hands the chunk stream to the
        // pipeline; release stops the mic, which ends the stream and lets STT
        // finalize. The icon flips only once capture actually began — start()
        // returns nil on failure (mic TCC not granted) or when already
        // recording (a second hotkey firing mid-hold changes nothing).
        let onStart: () -> Void = { [weak self] in
            guard let self else { return }
            guard self.coordinator != nil else {
                // No pipeline (missing key / store failure / still assembling):
                // don't record audio nobody can transcribe.
                Log.event("hotkey_ignored_no_pipeline", category: .session)
                return
            }
            guard let stream = self.audioEngine?.start() else { return }
            self.statusItemController?.setRecording(true)
            self.audioSource?.provide(stream)
            self.pressContinuation?.yield(())
        }
        let onStop: () -> Void = { [weak self] in
            self?.statusItemController?.setRecording(false)
            self?.audioEngine?.stop()
        }

        // Fn push-to-talk (CGEventTap). Its liveness monitor surfaces ⚠︎ if
        // Accessibility is later revoked.
        let tap = FnHotkeyTap(
            onStart: onStart,
            onStop: onStop,
            onRevoked: { statusItemController.setPermissionWarning(true) }
        )
        if !tap.start() {
            // Accessibility not granted yet: surface ⚠︎ instead of crashing.
            statusItemController.setPermissionWarning(true)
        }
        self.hotkeyTap = tap

        // Alternative hotkey (⌥Space, KeyboardShortcuts). Independent of the Fn
        // tap and of Accessibility, so it works even in the untrusted state.
        let alt = AltHotkeyMonitor(onStart: onStart, onStop: onStop)
        alt.start()
        self.altHotkey = alt

        // The real pipeline (E2E wiring PR-B): press → audio → Speechmatics →
        // Gemini formatting → paste, with write-ahead history. Assembled AFTER
        // the hotkeys and menu are wired, asynchronously: the first Keychain
        // read can put up a user-consent dialog, and the app must stay fully
        // interactive (hotkeys log-and-ignore until the pipeline is ready). If
        // assembly fails (missing STT key, store open failure) the hotkeys stay
        // inert and the status item latches ⚠︎.
        Task {
            await self.assemblePipeline(
                inserter: pasteSimulator,
                focus: contextProvider,
                audioSource: audioSource,
                statusItemController: statusItemController
            )
        }
    }

    /// Composition root: construct the provider clients, stores, and the
    /// coordinator. `coordinator` stays nil on any hard failure — the hotkeys
    /// check it per press.
    private func assemblePipeline(
        inserter: PasteSimulator,
        focus: InsertionContextProvider,
        audioSource: HotkeyAudioSource,
        statusItemController: StatusItemController
    ) async {
        // All blocking work runs off the main actor, concurrently: each
        // Keychain read can stall on securityd (or a consent dialog on the
        // first read of a CLI-created item), and the SQLite open + schema/FTS5
        // migration is disk-bound — none of it may freeze the menu/hotkeys
        // (review finding: the store open on the main actor reintroduced the
        // exact "looks hotkey-dead" window the async assembly exists to avoid).
        let secrets = KeychainSecretStore()
        let sttKeyTask = Task.detached { secrets.read(.speechmaticsAPIKey) }
        let geminiKeyTask = Task.detached { secrets.read(.geminiAPIKey) }
        let storesTask = Task.detached { () -> Result<(HistoryStore, DictionaryStore), any Error> in
            do {
                let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("dev.newt.Koe", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let history = try HistoryStore(path: dir.appendingPathComponent("history.sqlite").path)
                let dictionary = try DictionaryStore(path: dir.appendingPathComponent("dictionary.sqlite").path)
                return .success((history, dictionary))
            } catch {
                return .failure(error)
            }
        }

        // Stores live in Application Support. Without the history DB the
        // invariant-1 write-ahead net is gone, so a failed open hard-blocks
        // rather than running a pipeline that could lose text silently. The
        // stores are kept even when the STT key is missing — History UI (M7)
        // works without dictation.
        let history: HistoryStore
        let dictionary: DictionaryStore
        switch await storesTask.value {
        case .success(let stores):
            (history, dictionary) = stores
        case .failure:
            Log.error("config_store_open_failed", category: .history)
            statusItemController.setConfigurationWarning(true)
            return
        }
        self.historyStore = history
        self.dictionaryStore = dictionary

        // No STT key → no dictation is possible at all: hard block with ⚠︎.
        guard let sttKey = await sttKeyTask.value else {
            Log.error("config_missing_stt_key", category: .app)
            statusItemController.setConfigurationWarning(true)
            return
        }

        let stt = SpeechmaticsClient(apiKey: sttKey)
        // Hide TLS+WebSocket setup (~300ms) before the first press.
        Task { try? await stt.prewarm() }

        // No Gemini key → dictation still works, unformatted: MissingKeyLLMClient
        // fails instantly and LLMFormatter degrades to the raw transcript
        // (invariant 2) — strictly better than blocking.
        let llmClient: any LLMClient
        if let geminiKey = await geminiKeyTask.value {
            llmClient = GeminiClient(apiKey: geminiKey)
        } else {
            Log.error("config_missing_llm_key", category: .app)
            llmClient = MissingKeyLLMClient()
        }

        // STT vocabulary is fetched fresh per utterance; the LLM prompt
        // dictionary is a launch snapshot (live refresh lands with M10's
        // dictionary editor — logged gap, decisions.md session 13). Partials
        // feed the HUD's live line only — never persisted or logged.
        let hud = hudController
        let vocab: @Sendable () async -> [STTVocabTerm] = {
            (try? await dictionary.sttVocabulary()) ?? []
        }
        // M4-T3 failure ladder: streaming (finals tail bounded by the 2s
        // §10.3 leg) → one batch resend → persist WAV + HUD retry.
        let transcriber = ResilientTranscriber(
            streaming: STTTranscriber(
                client: stt,
                vocab: vocab,
                onPartial: { text, context in hud?.partial(text, context) },
                tailTimeout: KoeConstants.sttFinalTimeout
            ),
            batch: SpeechmaticsBatchClient(apiKey: sttKey),
            store: TempAudioStore(),
            vocab: vocab
        )

        let entries = (try? await dictionary.promptEntries()) ?? []
        let formatter = LLMFormatter(client: llmClient, dictionary: entries)
        let coordinator = SessionCoordinator(
            audio: audioSource,
            stt: transcriber,
            formatter: formatter,
            inserter: inserter,
            history: history,
            focus: focus,
            ui: hud,
            recovery: transcriber
        )
        self.coordinator = coordinator
        hud?.onRetry = { handle in
            Log.event("hud_retry_pressed", category: .session)
            Task { await coordinator.startRetry(handle) }
        }
        Log.event("pipeline_ready", category: .session)
    }
}

/// Stands in for Gemini when no API key is configured: fails instantly (no
/// network) so `LLMFormatter`'s degrade path inserts the raw transcript.
private struct MissingKeyLLMClient: LLMClient {
    func complete(system: String, user: String) async throws -> String {
        throw LLMError.http(status: 401)
    }
}
