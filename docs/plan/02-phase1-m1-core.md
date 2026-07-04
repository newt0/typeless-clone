# Phase 1 — Milestones M0–M3 (project, state machine, hotkey, audio)

Prereq reading: `00-overview.md`. Task IDs are `M<milestone>-T<n>`; dependencies reference those IDs. Each milestone should land as one or a few PRs; `pnpm`-style checks here are `xcodebuild build` + unit tests.

---

## M0 — Project bootstrap

### M0-T1 Xcode project + repo layout

- macOS app target "Koe": deployment target macOS 14, arch arm64 only, Swift 5.10+, App Sandbox **off**, Hardened Runtime on. `LSUIElement = true` (no Dock icon), `NSMicrophoneUsageDescription` set. Choose the permanent bundle ID (never change it — TCC grants bind to it).
- SwiftPM deps (pinned): GRDB, KeyboardShortcuts. Nothing else.
- Source layout one directory per module from the table in `00-overview.md` (e.g. `Koe/Hotkey/`, `Koe/Audio/`, `Koe/Session/`, `Koe/STT/`, `Koe/Formatting/`, `Koe/Insertion/`, `Koe/HUD/`, `Koe/Storage/`, `Koe/Settings/`, `Koe/AppServices/`), plus `KoeTests`.
- `Constants.swift` centralizing tunable numbers (pre-delay 100ms, restore wait 300ms, misfire 0.3s, chunk threshold 500 chars, timeouts 2.0/1.5/6.0/0.5s) each commented `[tune in Phase 0]`.
- Acceptance: builds and runs as a menu-bar-only app; unit test target runs.
- Design ref: §3, §7.7.

### M0-T2 App shell: status item, logging, Keychain

- `NSStatusItem` with states (normal / recording / permission-warning ⚠︎) and menu: History, Settings, Pause, Quit (History/Settings can be placeholders).
- `Log` wrapper over OSLog enforcing invariant 4: API takes event names + numeric/enum metadata only; no free-form string interpolation of user content (transcripts, formatted text, dictionary terms). Document the rule in the file header; it is a code-review checklist item.
- `KeychainStore` helper: get/set/delete generic passwords for STT/LLM API keys (invariant 5). Settings never mirror keys into UserDefaults.
- Acceptance: unit tests for KeychainStore; grep shows no direct `os_log`/`print` usage outside `Log`.
- Design ref: §7.7, §9.3.
- Depends: M0-T1.

---

## M1 — DictationSession state machine

### M1-T1 State machine actor

- `actor DictationSession` owning one dictation lifecycle: `idle → recording → transcribing → formatting → inserting → done/error` with edges exactly as in `00-overview.md` (cancel, misfire discard, degradation path). Illegal transitions are programmer errors (assert + log event).
- Emits an observable state stream (`AsyncStream` or `@Observable` projection) consumed later by HUD (M9) and status item. UI is a pure render of this state — no logic in UI.
- Stage timestamps recorded on every transition (`t_keydown … t_insert_done`) into a `DictationMetrics` value handed to HistoryStore/telemetry later (M7/M10).
- Acceptance: unit tests cover every legal transition, the cancel path, misfire discard (<0.3s + silence flag → never reaches STT), and degradation (`formatting → inserting(raw)`).
- Design ref: §7.2, §8.4.
- Depends: M0-T1.

### M1-T2 Session orchestration + FIFO insertion lock

- `SessionCoordinator` creating a `DictationSession` per hotkey press. Pipelines of consecutive utterances may overlap (recording of N+1 while N is formatting) but insertion is serialized through a global FIFO — utterance N+1 never inserts before N resolved (done or landed on clipboard fallback).
- Collaborator protocols defined here as stubs so M2–M6 plug in: `AudioCapturing`, `STTClient`, `Formatting`, `TextInserting`, `ContextProviding`, `HistoryWriting`.
- Acceptance: unit test with mock collaborators proves two overlapping sessions insert in order; a failed insert on N (fallback landing) does not block N+1 forever.
- Design ref: §7.2, §10.4.
- Depends: M1-T1.

---

## M2 — HotkeyManager

### M2-T1 CGEventTap for Fn

- `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: keyDown|keyUp|flagsChanged)`. Fn detection = `flagsChanged` with keycode 63 (`kVK_Function`); modifier keys never produce keyDown. Press-and-hold = start on Fn-down, stop on Fn-up; also support tap-to-start/tap-to-stop toggle (manual only, no VAD in P0).
- While Fn is the active hotkey, consume the event (return nil from the callback) to suppress the system globe-key action. OS may still act on it — onboarding (M11) tells the user to set globe key to "Do Nothing"; do not try to fully own the key in code.
- Guard startup with `AXIsProcessTrusted()`; if untrusted, surface permission-warning state instead of crashing.
- Acceptance: manual test — Fn hold triggers press/release callbacks; emoji palette does not appear (after globe-key setting change); no Input Monitoring TCC prompt ever appears.
- Design ref: §7.3, §11.1.
- Depends: M0-T2, M1-T2.

### M2-T2 Tap liveness + alternative hotkey

- On `kCGEventTapDisabledByTimeout` / `kCGEventTapDisabledByUserInput` events: immediately `CGEvent.tapEnable` (the classic "hotkey silently dies" bug). Additionally a 60s timer verifies tap validity and `AXIsProcessTrusted()`; on revocation → status item ⚠︎ + re-guidance (M11-T3 hooks in here).
- Alternative hotkey for users who can't/won't use Fn: default ⌥Space long-press, configurable via KeyboardShortcuts library; same press/release semantics.
- Acceptance: simulated tap-disable event re-enables within one event cycle; alt hotkey drives a full session identically to Fn.
- Design ref: §7.3, §11.3, risk R7.
- Depends: M2-T1.

---

## M3 — AudioCapture

### M3-T1 Engine, format conversion, session buffer

- `AVAudioEngine` configured at app launch and kept stopped-but-ready; hotkey press only calls start (FR-01: press→recording ≤200ms, expect ~50ms). Verify the orange mic indicator lights only while recording.
- Input tap → `AVAudioConverter` → 16kHz / mono / Int16, emitted to the STT client in 20–50ms chunks via `AsyncStream<Data>`. No client-side NR/AGC — send raw audio.
- Keep the entire session audio in memory for STT batch resend (M4-T3); cap 20 minutes (≈38MB) then stop recording with HUD notice.
- Wrap recording→insertion in `ProcessInfo.processInfo.beginActivity(options: [.userInitiated])` (App Nap protection).
- Acceptance: unit test converter output format; measured press→first-buffer latency logged and ≤200ms; mic indicator behavior manually confirmed.
- Design ref: §7.4, §8.
- Depends: M1-T2.

### M3-T2 Device-switch survival

- Observe default-input route changes (AirPods disconnect etc.). During recording: fall back to built-in mic and **continue the same session**; notify HUD of the switch.
- Setting "prefer built-in mic" (default ON) — avoid Bluetooth HFP mics that degrade STT accuracy.
- Acceptance: manual test — disconnect AirPods mid-utterance; recording continues on built-in mic, HUD shows the switch, transcript covers both segments.
- Design ref: §7.4, §10.2.
- Depends: M3-T1.
