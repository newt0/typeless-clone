# Decision log

## 2026-07-06 (session 9 — M3-T2 device-switch survival)

- **Pure/adapter split (same as M3-T1).** `InputDeviceSelector` + `AudioInputDevice` in `KoeCore` decide which input device to record from (`select`) and whether a mid-recording route change warrants switching (`resolveSwitch`), unit-tested (+11); the untestable CoreAudio enumeration/listener glue is `App/AudioDeviceObserver.swift` and the device-pinning/tap-rebind lives in `AudioCaptureEngine`.
- **"Prefer built-in mic" default ON, implemented by pinning.** macOS otherwise follows the system default onto a freshly-connected Bluetooth headset (HFP, degrades STT). The engine pins the selected device via `kAudioOutputUnitProperty_CurrentDevice` on the input node's audio unit, so a headset connecting mid-session does **not** steal capture. The pref is a `preferBuiltIn: () -> Bool` closure re-read each start (UserDefaults key `preferBuiltInMic`, default true) so a future Settings toggle needs no engine rebuild.
- **Device-switch continues the same session (invariant 1).** On a default-input change (`AudioDeviceObserver`) or `.AVAudioEngineConfigurationChange` (the pinned device vanished), `resolveSwitch` re-selects; a `.switchTo` stops the engine, re-pins, rebuilds only the `AVAudioConverter` for the new input format, `rebind`s it into the existing `TapState` (so the `SessionAudioBuffer` and chunk `AsyncStream` survive), reinstalls the tap, and restarts — the transcript spans both devices. Switch is notified via `onDeviceSwitched` for the M9 HUD (logged `audio_device_switched`; the device name never hits `Log`, invariant 4).
- **Swift 6 concurrency:** `AudioDeviceObserver` is `@unchecked Sendable` so the HAL listener block can weak-capture it; the block hops `DispatchQueue.main.async` → `MainActor.assumeIsolated` before touching main-only state, mirroring the `FnHotkeyTap` assume-isolated pattern.

### M3-T2 code-review fixes (high, 8 findings)

- **`pin()` returns `Bool`; a switch is only reported when it took effect** (finding [0], confirmed). If the HAL device UID no longer resolves or `AudioUnitSetProperty` fails, `handleRouteChange` still keeps capture alive (invariant 1 — no session drop) but records the OS fallback in `currentDevice` and logs `audio_device_switch_pin_failed` instead of firing `onDeviceSwitched`/`audio_device_switched` — so the M9 HUD never claims a switch that didn't happen.
- **`engine.reset()` after every pin, before reading `inputFormat`** ([1]/[2]/[7], plausible). Forces the input node to re-read the newly-pinned device's native format so the converter/tap aren't built from a stale (previous-device) format → garbled post-switch audio.
- **Device switch builds a new `TapState` carrying the buffer over, rather than mutating `converter`** ([4], plausible). Keeps `TapState.converter` a `let` so the `@unchecked Sendable` justification stays "immutable + tap-thread-local only" — no main-thread write racing a possibly-in-flight tap callback. `carryOverBuffer()` is read on main only after `engine.stop()`+`removeTap`; `firstChunkLogged` is seeded from the carried buffer so latency isn't re-logged post-switch.
- **`AudioDeviceObserver` caches the device snapshot (+ UID→AudioDeviceID map), warmed at launch and refreshed on HAL change** ([5]/[8], plausible). The hotkey path (`start()`/`pin()`) now reads devices in memory instead of firing a burst of synchronous `AudioObjectGetPropertyData` round-trips inside the FR-01 ≤200ms budget.
- **`snapshot`/`refresh` resolve the system default by matching its `AudioDeviceID` against the map already built, dropping a redundant per-call UID round-trip** ([6], confirmed).
- **UserDefaults key centralized in `AppDefaultsKey.preferBuiltInMic`** ([10]) so the M10 Settings UI can't desync on a typo'd literal.
- **Not changed:** `AudioDeviceObserver`'s main-actor discipline is enforced by convention + `@MainActor` on its API, not by making the class `@MainActor` ([9]) — consistent with the accepted `FnHotkeyTap`/`TapState` `@unchecked Sendable` pattern; a full actor conversion fights the nonisolated `deinit` that must remove the HAL listeners.

## 2026-07-06 (session 8 — M3-T1 audio engine + buffer)

- **Pure/adapter split for audio.** `AudioFormatSpec` (16kHz/mono/PCM16 wire numbers + chunk-frame/byte-budget math) and `SessionAudioBuffer` (in-memory session audio, 20-min/≈38MB cap → truncate-and-signal `.capReached`) live in `KoeCore` and are unit-tested (+12); the untestable `AVAudioEngine`/`AVAudioConverter` glue is `App/AudioCaptureEngine.swift`, mirroring the `HotkeyEngine`/`FnHotkeyTap` pattern. Non-Sendable AVFoundation state is isolated in a private `TapState` (`@unchecked Sendable`) only ever touched on CoreAudio's serialized tap thread.
- **`AudioConverter` fed one tap buffer per callback** (`.haveData` once, then `.noDataNow`); output capacity sized by sample-rate ratio. Raw audio only — no client NR/AGC (invariant 8). Chunk cadence ~40ms (`KoeConstants.audioChunkDuration`), the tap `bufferSize` a hint CoreAudio may not honour exactly.

### M3-T1 code-review fixes (high, 2 confirmed)

- **`AudioCaptureEngine.start()` returns `ChunkStream?`, not a stub finished stream.** `nil` on both start-failure (bad input format / converter init / `engine.start()` throw — e.g. mic TCC not granted) and already-recording. AppDelegate flips the icon to "recording" and (re)arms the drain task only on a non-nil return, so (a) a failed start can't leave the icon lying "recording" while zero audio is captured (invariant 1), and (b) a second hotkey firing mid-hold no longer cancels the live drain task and orphans the still-fed real stream (unbounded buffering).
- **Cross-hotkey teardown (Fn held + a stray ⌥Space tap fires the shared `onStop`) stays a known limitation of the QA wiring**, consistent with the logged "both hotkeys active concurrently in P0" stance — the real fix is `SessionCoordinator` owning session lifecycle (wired in M4/M5), not source-ownership bookkeeping in throwaway AppDelegate glue.

## 2026-07-05 (session 7 — M2-T2 liveness + alt hotkey)

- **Liveness poll uses a `Task` sleep loop, not `Timer`.** Swift 6 marks `Timer.scheduledTimer`'s block `@Sendable`, which can't capture the `@MainActor` `FnHotkeyTap`; a `Task` created in the actor context inherits isolation and captures `self` cleanly. Interval `KoeConstants.tapLivenessInterval` (60s). The check maps `AXIsProcessTrusted()` × `CGEvent.tapIsEnabled` through the pure `TapLiveness.evaluate` → healthy / re-enable / revoked; revoked tears the tap down, resets the engine, and fires `onRevoked` (⚠︎). Full re-arm-after-re-grant guidance stays M11.
- **Alt hotkey via KeyboardShortcuts, pinned `exactVersion: 3.0.1`** (added to `project.yml` packages, app-target only — not the KoeKit SwiftPM package). Default ⌥Space, remappable in Settings (M10). Uses Carbon `RegisterEventHotKey` → no Input Monitoring TCC and no Accessibility needed, so it works even while the Fn tap is untrusted. `AltHotkeyMonitor` drives the same `HotkeyEngine` (hold mode) as `FnHotkeyTap` for identical press/hold semantics.
- **Both hotkeys active concurrently in P0.** Fn and ⌥Space are both registered; either drives a session. Making them mutually exclusive is a SettingsStore concern (M10) — deferred rather than hard-coding one.

### M2-T2 code-review fixes (high, 6 confirmed)

- **Status item is now a two-flag model (`recording` transient + `permissionWarning` latched), not a single tristate enum.** A shared `onStop`/`onStart` from the (Accessibility-free) alt hotkey was silently overwriting the ⚠︎ set by Fn-tap revocation. Recording is a transient overlay; the latched warning shows through again the moment recording stops, so a working alt hotkey can't hide a dead Fn path.
- **Periodic liveness `.needsReenable` now resets the engine** (matching the immediate `tapDisabled*` handler) — a Fn key-up lost while the tap was silently disabled no longer leaves recording latched on for a full extra press cycle.
- **Shared `HotkeyActivation` helper** replaces the duplicated start/stop+log switch that `FnHotkeyTap` and `AltHotkeyMonitor` each carried, so the two hotkeys can't drift in emitted events/analytics.
- **`tapLivenessInterval` typed `Duration`** (was `TimeInterval`) to match every other tunable in `Constants.swift`; call site passes it straight to `Task.sleep(for:)`.
- **`Package.resolved` untracked (was committed).** The single root file is shared by the KoeKit SwiftPM package (`swift test` → GRDB only) and the Koe.app Xcode target (`xcodebuild` → GRDB + KeyboardShortcuts); each rewrites it to a different superset/subset on every build, so no committed copy stays clean. Reproducibility is pinned in the manifests instead (GRDB in `Package.swift`, KeyboardShortcuts `exactVersion` in `project.yml`). Reverses the earlier "commit Package.resolved" choice now that a second toolchain resolves the same file.
- **Stale `FnHotkeyTap` comments corrected**: the alt hotkey is a separate KeyboardShortcuts/Carbon path, not a future expansion of this tap's `flagsChanged` mask.

## 2026-07-05 (session 6 — M2-T1 Fn hotkey)

- **Hotkey split: pure engine in KoeCore + CGEventTap in the app target** (mirrors the STT `WebSocketChannel` seam). `HotkeyEngine` (hold/toggle → start/stop, key-repeat/spurious-transition idempotent) and `FnKey` (keycode 63 + `maskSecondaryFn` → `.down`/`.up`) are pure and unit-tested (+20 tests); `App/FnHotkeyTap.swift` is the thin, untestable adapter that owns the real tap. Keeps activation semantics testable without synthesizing system events.
- **Tap callback runs on the main run loop; `MainActor.assumeIsolated` (no async hop).** The source is installed on `CFRunLoopGetMain()`, so the `@convention(c)` trampoline is always on the main thread — asserting isolation avoids a dispatch hop on the press→recording latency path (FR-01). `@preconcurrency import CoreGraphics` silences the spurious non-`Sendable` `CGEvent` diagnostic across that boundary.
- **Immediate `tapDisabled*` re-enable included in M2-T1; the 60s liveness timer + revocation → ⚠︎ re-guidance stay M2-T2.** Without the inline re-enable the tap silently dies on the first timeout, which would make the M2-T1 manual QA (Fn hold triggers callbacks) flaky. The periodic verification/revocation handling is genuinely M2-T2 and left there.
- **No `deinit` teardown on `FnHotkeyTap`.** The single instance is owned by `AppDelegate` for the whole app lifetime; a nonisolated `deinit` cannot touch the `@MainActor` tap/source state anyway. Teardown lives in `stop()`.
- **Tap mask is `flagsChanged`-only in M2-T1, not the plan's `keyDown|keyUp|flagsChanged`.** M2-T1 consumes only the Fn key (a `flagsChanged` event); subscribing to key-down/up would route every system-wide keystroke through our main-thread callback before the M2-T2 alt hotkey exists to use them. The two are added back with the alt-hotkey binding. (Post-review cleanup finding.)
- **Re-enable path calls `engine.reset()`.** A tap disabled mid-hold can miss the Fn key-up, latching `isActive` true; the `tapDisabled*` recovery now resets the engine (emitting `.stop` if needed) so recording state can't stick on. (Post-review correctness finding.)

## 2026-07-05 (session 5 — M4 follow-up code-review fixes)

Second high-effort `/code-review` on the merged M4 adapter surfaced 10 confirmed findings; all fixed on `fix/m4-speechmatics-review` (+7 regression tests, 95 total green).

- **Session gate (`accepting`)**: `send`/`endUtterance` now require a live session (StartRecognition sent, EndOfStream not yet sent), not merely a non-nil `channel`. Fixes: send/endUtterance after `prewarm` alone, send-after-`endUtterance`, and double-`endUtterance` — all now throw `.notStarted` instead of silently transmitting frames on an unstarted/ended session.
- **Begin mutex (`beginning`)**: set synchronously at `beginUtterance` entry (before any `await`), so an overlapping begin throws `STTError.busy` instead of opening a duplicate socket and spawning a racing receive loop. New `.busy` case added.
- **Idle-close self-heal**: `openSession` sends StartRecognition and, if the (reused, possibly idle-closed) socket rejects it, drops the socket and reconnects once. Delivers the STTClient "reconnect if the prewarmed socket has closed" contract at `beginUtterance` — with no ping on the hot path (only reconnects when a send actually fails). Restart path also nils `channel` *before* `await close()` so nothing reuses the closing socket.
- **Error normalization**: `send`/`endUtterance`/`openSession` map raw transport errors (`URLError`, …) to `STTError` via the new `STTError.from(_:)` helper, which also de-duplicates the `catch STTError / else .connection` idiom shared with `verify`/`ensureChannel`.
- **`sttConnectTimeout` moved to `KoeConstants`** (part of the timeout ladder, tuned in Phase 0) instead of a buried default literal.

## 2026-07-05 (session 5 — M4-T1/T2 Speechmatics STT adapter)

- **`STTClient` protocol in KoeCore, `SpeechmaticsClient` adapter in KoeProviders** — mirrors the LLM split (`LLMClient`/`GeminiClient`). Delivered M4-T1 + M4-T2 in one PR (as M6-T1 did protocol+adapter together). Built Speechmatics as the design's provisional primary; keys are Keychain-validated, so S2's formal A/B stays a separate later task (STATUS M4-T2 was `blocked(S2 decision)` only for the A/B, not for building the primary).
- **The design's `ForceEndOfUtterance` message does not exist in Speechmatics RT v2** (verified via context7 on the current SDK). RT v2's client→server terminator is `EndOfStream { last_seq_no }`; the VAD-based `conversation_config.end_of_utterance_silence_trigger` → server `EndOfUtterance` is a different feature and not for push-to-talk. Koe is push-to-talk (key-up = definitive end, no VAD per non-goals), so `endUtterance()` sends `EndOfStream`, which flushes the remaining finals; the stream ends on `EndOfTranscript`. One socket = one utterance; the next `prewarm`/`beginUtterance` opens a fresh socket.
- **WebSocket transport is a seam (`WebSocketChannel`)** so the wire protocol (StartRecognition config, `additional_vocab` mapping, invariant-8 absence of formatting options, partial→final parsing, `EndOfStream` seq_no) is unit-tested deterministically with a fake actor — no network, CI stays keyless/green. Real impl `URLSessionWebSocketChannel` verifies the connection with a ping in `prewarm` (surfaces auth/handshake failure before the first audio frame; 401/403 → `STTError.auth`).
- **Adapter is an `actor`** (unlike stateless `GeminiClient`): it owns the socket, the send seq counter, and the event-stream continuation. The receive loop is a nonisolated `Task` touching only Sendable values (channel + continuation), so audio `send` interleaves with receiving.
- **Endpoint default `wss://eu2.rt.speechmatics.com/v2`, `operating_point: enhanced`, `max_delay: 1.0` — provider-specific, so they live as adapter defaults, not in `KoeConstants`** (which is provider-neutral). Japan RTT (~220ms to EU) and `max_delay` are `[tune in Phase 0 / S2]`.
- **`additional_vocab` from `[STTVocabTerm]`**: readings normalized to full-width katakana in the adapter (hiragana→katakana + half-width→full-width), capped at 1,000 (`Log`s the count, no body text). invariant 8: no `enable_entities`/`punctuation_overrides`/`output_locale` sent — asserted by a test.
- **Live integration test is opt-in** (`KOE_LIVE_TESTS=1` + `SPEECHMATICS_API_KEY`/Keychain + a `KOE_STT_SAMPLE_WAV` 16kHz mono PCM16 WAV path); skips without all three so CI/default stays green. Owner supplies the WAV (S2 recordings still owner-blocked).
- **Deferred (this PR's scope excludes):** M4-T3 (batch resend + retry UI) — hard-depends on M3 (session audio buffer) and M9 (HUD retry button), both `todo`. `STTClient`→`Transcribing` bridge — deferred to M2/M3 live-audio wiring (a batch bridge now would throw away streaming/partials). ToS §10.3 retention/training-license conflict is a known risk (Design §9), acceptable for Phase-1 personal dogfood, revisit before beta.

## 2026-07-05 (session 4 — M6-T1 Gemini adapter)

- **New `KoeProviders` target** for STT/LLM API adapters (URLSession; no third-party deps), keeping KoeCore pure. GeminiClient lives here; `LLMClient`/`LLMFormatter` protocols+logic stay in KoeCore.
- **`LLMClient` is non-streaming for P0** (`complete(system:user:) -> String`). The pipeline inserts once (invariant 6) and the `Formatting` seam is already non-streaming, so streaming buys only perceived latency — deferred as a TTFT optimization.
- **Gemini thinking disabled** via `generationConfig.thinkingConfig.thinkingBudget = 0` (Design §4/§8). Verified by curl: 0.81s with it off vs 1.46s default — it works and matters.
- **Live formatting verified**: 「えーとですね、明日、いや明後日に資料を送りますので…」→「明後日に資料を送りますので、よろしくお願いします。」(filler removed, self-correction merged, punctuation added).
- **Latency caveat**: the same call took ~90s inside the `swift test` process (likely IPv6 happy-eyeballs / sandbox first-connection), while curl is ~0.8s. Not a code defect; to be measured properly in Phase 0 S4 on the real app.
- **Live integration test is opt-in** (`KOE_LIVE_TESTS=1` + Keychain/env key) so the default suite stays fast and CI stays keyless (test skips without the flag/key). Keyed results are pasted into the PR per the workflow.
- Built Gemini as primary per the design's provisional selection; the S3 golden-set quality A/B is a separate task (needs the golden set authored) and can run against this adapter later.

## 2026-07-04 (session 3 — M7-T1 history/GRDB)

- **GRDB isolated in a new `KoeStorage` target** (KoeCore stays dependency-free). `Package.resolved` is now committed (removed from .gitignore) for reproducible dependency versions; GRDB pinned at 7.11.1.
- **History FTS is a hybrid: FTS5 trigram (≥3 chars) + `LIKE` fallback (1–2 chars).** Trigram cannot index 1–2 character terms, but 2-char words are ubiquitous in Japanese (会議, 資料, 送付), so short queries would silently return nothing with FTS alone. The LIKE scan is fine at personal-history scale and always correct; FTS keeps longer queries fast as history grows. Honors the design's FTS5 choice while fixing the Japanese gap.
- **Write-ahead in stages** (raw transcript → formatted → insert result) via `HistoryWriting`; a crash after any stage leaves the transcript recoverable (invariant 1). `app_bundle_id`/`prompt_version`/`latency` columns exist but are populated later when the coordinator is wired with ContextProvider.

## 2026-07-04 (session 3 — M6-T3 chunk/validate)

- **M6-T3 split into pure logic now + async ladder later.** `TranscriptChunker` (sentence-boundary splitting, never mid-sentence — an oversized lone sentence stays one chunk) and `OutputValidator` (empty / >30% shrink / instruction-leakage → `degrade`) are pure and tested here. The retry/timeout orchestration lands with M6-T1 when a real `LLMClient` exists.
- **Leakage heuristics**: flag own-prompt fragments, code fences, and whole-output wrapped in ASCII/curly double quotes; Japanese 「」 is NOT flagged (legitimate quoting → too many false positives).

## 2026-07-04 (session 3 — M6-T2 prompt assembly)

- **System prompt written in Japanese**, template `current` v1.0.0, since the task is Japanese-text formatting. Blocks ordered stable→volatile (role, formatting rules | style, dictionary, app context | transcript) for prompt-cache friendliness (Design §5.2).
- **Template version = `semver + SHA-256(text)[:8]`** so accidental drift is caught even without a semver bump; recorded per dictation for quality attribution (§5.6).
- **Injection boundary hardened**: transcript wrapped in `<transcript>` tags AND any literal `<transcript>`/`</transcript>` in the transcript is stripped (STT never emits real tags, so nothing meaningful is lost). Role rules also instruct the model to treat tag content as data.
- **`docs/code-sample/Typeless.app` (competitor binary) deleted** at owner request; not used. Implementation stays clean-room from own design + cited OSS (see prior session note recommending against decompilation).
- **claude-api skill not loaded** for this task: pure provider-agnostic prompt-string assembly, no API call/model/param choice. Will load it for M6-T1 (Gemini/Bedrock adapters).

Audit trail replacing human code review (see `docs/plan/06-autonomous-workflow.md`). One dated entry per non-obvious decision: what was decided, why, alternatives rejected. Newest first.

## 2026-07-04 (session 3 — M0-T2 app shell)

- **Bundle ID `dev.newt.Koe`** (owner decision, permanent). App Sandbox off; ad-hoc signing (`CODE_SIGN_IDENTITY "-"`) for local build/run; CI builds with `CODE_SIGNING_ALLOWED=NO`.
- **XcodeGen for the app target.** `project.yml` is the source of truth; the generated `Koe.xcodeproj` is git-ignored and regenerated (`xcodegen generate`). CI installs xcodegen, generates, and `xcodebuild`s the app so app-target breakage is caught. Chosen over a hand-written pbxproj (unmaintainable) and Tuist (heavier).
- **`Log` wrapper takes only `StaticString` + optional `Int`** — structurally impossible to pass body text into a log (invariant 4), stronger than a convention. CI greps ban direct `os_log`/`NSLog`/`print` outside `Log.swift` across both `Sources` and `App`.
- **`SecretStore` protocol** with `KeychainSecretStore` (real, Security API) + `InMemorySecretStore` (tests/previews). Contract is unit-tested via the in-memory impl because the login keychain is not reliable on CI runners; the Keychain adapter is runtime-verified on the dev machine.

## 2026-07-04 (session 3 — M1-T2)

- **Coordinator seams are stage-named, not client-named.** M1-T2's plan lists an `STTClient` seam, but M4-T1 defines the richer streaming `STTClient` protocol. To avoid two conflicting protocols, the coordinator's seam is `Transcribing` (audio → transcript); an M4 `STTClient` adapter will satisfy it. Same for the other stages (`AudioCapturing`, `Formatting`, `TextInserting`, `HistoryWriting`, `ContextProviding`).
- **`UtteranceContext { index }` threaded through every stage.** Gives stages a stable FIFO id for logging/metrics and makes overlap ordering deterministically testable (the id is fixed at reserve time, independent of concurrent scheduling).
- **FIFO release is structural (exactly-once), not flag-guarded.** `run()` calls `serializer.complete` in exactly one place after the stages return (success or failure); `waitTurn` is idempotent for the served ticket. Avoids a mutable captured `var` that tripped Swift 6's `sending` data-race check.

## 2026-07-04 (session 2 — first code)

- **Environment blockers found**: full Xcode is NOT installed (only Command Line Tools) → the macOS `.app` target, entitlements, signing, and running the app are blocked on an owner Xcode install. `gh` is not authenticated in Claude's shell (no `~/.config/gh`, env PAT returns 401) → push/PR are blocked. Swift 6.3 toolchain works, so pure-logic development proceeds.
- **Architecture: fat SwiftPM package + thin app shell.** All framework-light logic lives in a SwiftPM package (`KoeKit` → `KoeCore` target); the macOS app (AppKit HUD, CGEventTap, AVAudioEngine, entitlements, signing) becomes a thin Xcode target added once Xcode is installed and depends on the package locally. Rationale: maximizes what builds/tests without full Xcode and on CI; SwiftPM packages drop into an Xcode app cleanly. This re-scopes M0-T1 (the Xcode-app portion + bundle ID stay blocked).
- **Test framework: swift-testing (`import Testing`), not XCTest.** XCTest.framework is absent from the Command Line Tools; `Testing.framework` is present. `scripts/test.sh` adds the framework/dylib search paths swift-testing needs under CLT-only and defers to plain `swift test` where full Xcode exists (CI).
- **Illegal state transitions throw + log, not `assert`.** The plan said "assert + log"; `assertionFailure` aborts unit tests, so illegal transitions throw `DictationError.illegalTransition` (still logged via the `DictationEventLogger` seam). Keeps the guard unit-testable and never crashes a user session.
- **CI is keyless** (`.github/workflows/ci.yml`): macOS job = `swift build` + `scripts/test.sh`; Linux job = invariant greps (no direct logging outside the Log wrapper; no API keys in UserDefaults). No provider keys in GitHub secrets.

## 2026-07-04

- **Autonomous workflow adopted**: owner does not review code; quality = CI invariant guards + per-task `/code-review`+`/verify` + owner-triggered `/code-review ultra` per milestone + owner QA checklists in Japanese. Progress tracked in `docs/plan/STATUS.md`, not GitHub Issues (solo repo, avoid dual tracking).
- **CI kept keyless**: provider API keys never stored as GitHub secrets; keyed integration/golden-set tests run locally pre-merge with results pasted into the PR. Rationale: minimize key exposure surface; CI value is build+unit+invariant greps.
- **Plan docs created** (`docs/plan/00–06`): English for token efficiency per owner instruction; task-level acceptance criteria serve as the review contract.
