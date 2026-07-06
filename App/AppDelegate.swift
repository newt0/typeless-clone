import AppKit
import KoeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var hotkeyTap: FnHotkeyTap?
    private var altHotkey: AltHotkeyMonitor?
    private var audioEngine: AudioCaptureEngine?
    private var drainTask: Task<Void, Never>?
    private var pasteSimulator: PasteSimulator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app: no Dock icon, no app switcher (paired with LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        // Path 1 text insertion (M5-T2). Not yet wired into the pipeline (needs
        // STT+format); constructed now so the DEBUG QA hook can drive it.
        let pasteSimulator = PasteSimulator()
        self.pasteSimulator = pasteSimulator
        // DEBUG QA hooks (M5-T2/T3): the STT→format→paste pipeline isn't wired
        // yet, so these delayed test pastes let the owner exercise each insertion
        // path by hand. Click a menu item, then focus a target field within 2s.
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

        // Audio capture (M3-T1/M3-T2). Built prepared-but-stopped; the hotkey
        // only pays start(). Until the STT client is wired (M4), the produced
        // chunk stream is just drained so it can't build up — SessionAudioBuffer
        // is the retained copy for resend.
        //
        // "Prefer built-in mic" defaults ON (M3-T2) so a freshly-connected
        // Bluetooth headset (HFP, poor STT) can't hijack dictation; the closure
        // is re-read each start so a future Settings toggle takes effect without
        // rebuilding the engine. On a mid-session device switch (AirPods drop)
        // the HUD switch notice lands in M9 — for now capture continues silently
        // and the engine logs `audio_device_switched`.
        let audioEngine = AudioCaptureEngine(
            preferBuiltIn: { UserDefaults.standard.object(forKey: AppDefaultsKey.preferBuiltInMic) as? Bool ?? true },
            onCapReached: { statusItemController.setRecording(false) },
            onDeviceSwitched: { _ in /* M9 HUD switch notice */ }
        )
        self.audioEngine = audioEngine

        // Hotkey press starts recording and drains the chunk stream; release
        // stops it. Both hotkeys share this glue. The icon flips to "recording"
        // only once capture actually began — `start()` returns nil on failure
        // (e.g. mic TCC not granted) or when already recording, and in both
        // cases we leave the icon and the live drain task untouched (so a
        // second hotkey firing mid-hold can't orphan the running stream).
        let onStart: () -> Void = { [weak self] in
            guard let stream = audioEngine.start() else { return }
            statusItemController.setRecording(true)
            self?.drainTask?.cancel()
            self?.drainTask = Task { for await _ in stream {} }
        }
        let onStop: () -> Void = { [weak self] in
            statusItemController.setRecording(false)
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
    }
}
