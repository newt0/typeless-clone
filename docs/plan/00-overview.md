# Koe — Implementation Plan Overview

Source of truth: `docs/notes/2026-07-04-typeless-clone-design.md` (Japanese, 13 chapters — "Design §N" refs below point there). This file is a compressed English context so implementers do not need to read the full design doc. Read this file + the milestone file you are working on.

## Plan documents

| File | Contents |
| --- | --- |
| `00-overview.md` | This file: product, architecture, invariants, conventions |
| `01-phase0-spikes.md` | Phase 0 measurement spikes S1–S4 (insertion matrix, STT A/B, LLM golden set, E2E latency) |
| `02-phase1-m1-core.md` | M0 bootstrap, M1 state machine, M2 hotkey, M3 audio |
| `03-phase1-m2-pipeline.md` | M4 STT client, M5 text insertion, M6 LLM formatting |
| `04-phase1-m3-experience.md` | M7 history, M8 dictionary, M9 HUD, M10 settings/telemetry, M11 onboarding |
| `05-phase2-3-roadmap.md` | Phase 2 (relay server, distribution) and Phase 3 (P1 features) — outline only |

Execution order: Phase 0 (S1–S4) → Phase 1 milestones M0→M11 (M-order = dependency order). Phase 0 results fix the STT/LLM provider choice and several numeric constants marked **[tune in Phase 0]**.

## Product

**Koe**: system-wide Japanese voice input for macOS. Hold a global hotkey (Fn) → speak → streaming cloud STT → LLM cleanup (filler removal, self-correction merging, punctuation, style unification, ja/en mixed-script fixing) → paste result at the cursor of whatever app has focus.

Differentiators (in priority order): (1) Japanese formatting quality, (2) insertion reliability ("never lose text"), (3) latency — end-of-speech → inserted: P50 ≤1.5s / P95 ≤3.0s for standard utterances ≤30s; long utterances (>500 chars) separate target P95 ≤5s, (4) per-app context adaptation (P1, not MVP).

**MVP scope (P0)**: FR-01 global hotkey (press→recording ≤200ms) / FR-02 streaming transcription with live partials in HUD, ja-en mixed speech is a core requirement / FR-03 AI formatting / FR-04 cursor insertion with multi-stage fallback / FR-05 personal dictionary (STT keyword boost + LLM prompt injection) / FR-06 local history DB with full-text search / FR-07 onboarding ≤3min.

**Non-goals**: iOS/Windows/Web, billing, languages beyond ja+en mixing, fully-local offline STT (P2). Push-to-talk + manual toggle only in P0 — no VAD auto-stop (P1).

## Architecture

macOS native menu-bar agent. Phase 1 talks directly to STT/LLM APIs (no backend; API key in developer Keychain; **builds with keys never leave the developer machine**). Phase 2 inserts a thin stateless relay server (key custody, quota, prompt distribution) — see `05`.

### Tech stack

- Swift + SwiftUI (settings/onboarding) + AppKit (HUD `NSPanel`, `NSStatusItem`); Swift Concurrency (`actor`) for all pipeline state
- macOS 14+ (Sonoma), **arm64 only**, **App Sandbox permanently off** (Developer ID + notarization direct distribution)
- SwiftPM deps only, versions pinned: **GRDB** (SQLite + FTS5 history), **KeyboardShortcuts** (alt-hotkey UI), **Sparkle 2** (Phase 2). Networking = plain `URLSession` (`URLSessionWebSocketTask` for STT, SSE for LLM)
- TCC permissions: **Microphone + Accessibility only. Never request Input Monitoring** (consuming CGEventTap + synthetic events + AX reads are all covered by Accessibility)

### Providers (provisional — Phase 0 S2/S3 confirm)

| Role | Primary | Fallback candidates |
| --- | --- | --- |
| STT (streaming WS, 16kHz mono PCM16) | Speechmatics Enhanced RT (`additional_vocab`, ForceEndOfUtterance, zero retention by default) | Deepgram Nova-3 Multilingual (**must hardcode `mip_opt_out=true`**), Soniox v5 RT |
| LLM (formatting) | Gemini 2.5 Flash-Lite paid tier (TTFT ~0.35s, ~205 tok/s) — **explicitly disable thinking/reasoning** | Claude Haiku 4.5 on Bedrock Tokyo (ap-northeast-1) |

Both sit behind narrow protocols (`STTClient`: audio stream → partial/final transcript; `LLMClient`: prompt → streaming text). Vendor-specific features (dictionary injection format, endpointing message) stay inside adapters. No automatic failover in Phase 1 (STT failure → retry UI; LLM failure → degrade to raw transcript).

### Modules (Design §7)

| Module | Responsibility | Key APIs |
| --- | --- | --- |
| `DictationSession` (actor) | Single state machine per dictation; FIFO ordering; owns pipeline | Swift Concurrency |
| `HotkeyManager` | Fn/alt-key press+release detection, event consumption, tap liveness | CGEventTap, `flagsChanged` keycode 63 |
| `AudioCapture` | Mic capture, 16kHz/mono/Int16 conversion, session buffer, device-switch survival | AVAudioEngine, AVAudioConverter |
| `STTClient` (protocol) | Audio stream → partial/final transcript | URLSessionWebSocketTask |
| `Formatter` | Prompt assembly, chunking, streaming receive, output validation, degradation | URLSession (SSE) |
| `LLMClient` (protocol) | Prompt → formatted text stream | 〃 |
| `ContextProvider` | Frontmost app, AX focus reads (secure-field detection, insert verification) | NSWorkspace, AXUIElement |
| `TextInserter` | Insertion flow + 3-stage fallback (see `03`) | NSPasteboard, CGEvent |
| `HUDController` | Non-activating floating status panel | NSPanel + SwiftUI |
| `HistoryStore` | Write-ahead history records, FTS5 search | GRDB |
| `DictionaryStore` | Personal dictionary CRUD, feeds STT + LLM | GRDB |
| `SettingsStore` | Prefs (UserDefaults) + API keys (Keychain) | — |
| `AppServices` | Onboarding, permission monitoring, login item, update, telemetry | SMAppService etc. |

Dependency direction (strict, no back/cross refs): `HotkeyManager → DictationSession → {AudioCapture, STTClient, Formatter, ContextProvider, TextInserter, HUDController, HistoryStore}`; `Formatter → {LLMClient, DictionaryStore}`; `TextInserter → ContextProvider`; `SettingsStore` read by all.

### Dictation state machine (Design §7.2)

`idle → recording (key down; connections prewarmed) → transcribing (key up; send end-of-utterance) → formatting (final transcript; write-ahead to history) → inserting → done → idle`. Extra edges: `recording → idle` (cancel: Esc, or <0.3s press + silence = misfire, discard without STT); `transcribing → error` (STT dead after resend) → retry UI; `formatting → inserting` with raw transcript on LLM failure (degradation). Pipeline stages of consecutive utterances may overlap, but **`inserting` is globally serialized (FIFO)**.

## Invariants (enforce in every task's acceptance criteria)

1. **Zero text loss**: once spoken, text survives any combination of app/API/insert failures. Mechanisms: write-ahead history (record inserted at final-transcript time, updated later), failure landing = clipboard + HUD notice + history, in-memory audio retained per session for STT resend.
2. **LLM failure degrades to raw transcript insertion** (default; setting can change to clipboard-only). Never silently drop.
3. **Secure Input / secure fields**: if `IsSecureEventInputEnabled()` or focused element is `kAXSecureTextFieldSubrole` → do not insert AND do not touch the clipboard; HUD explains why.
4. **No body text leaves the user's Mac except to STT/LLM providers**; the only persistence is the local history DB. OSLog/telemetry/crash reports must never contain audio, transcripts, formatted text, or dictionary entries (lengths/hashes allowed). This is a code-review checklist item.
5. **API keys**: Keychain only (`kSecClassGenericPassword`). Never UserDefaults, files, or logs.
6. **Single batch insertion per utterance** — LLM output is received streaming but inserted once. Never insert sentence-by-sentence.
7. Deepgram adapter (if used) hardcodes `mip_opt_out=true`, not settable.
8. STT smart-formatting/ITN disabled; all text normalization (numbers, dates) is owned by the LLM prompt.

## Latency budget (Design §8 — post key-release, 15s utterance, ~100 output tokens)

| # | Segment | P50 | P95 |
| --- | --- | --- | --- |
| 1 | key-up → STT final | 300ms | 600ms |
| 2 | LLM TTFT | 400ms | 800ms |
| 3 | LLM generation | 500ms | 900ms |
| 4 | output validation | 10ms | 20ms |
| 5 | insertion (pre-delay + events + AX verify) | 200ms | 400ms |
| | **Total** | **≈1.4s** | **≈2.7s** |

Timeout ladder (Design §10.3): STT final 2.0s → batch resend; LLM TTFT 1.5s → 1 retry → degrade; LLM total 6.0s → degrade; each insertion stage 0.5s → next fallback. All **[tune in Phase 0]**.

Latency tactics already in the design: prewarm STT WebSocket (launch + key-down) and keep-alive LLM HTTP/2; stream audio during speech so most transcript is final at key-up; stream-receive LLM while inserting once; disable LLM reasoning.

Instrumentation: per dictation record `t_keydown, t_rec_start, t_keyup, t_stt_final, t_llm_first_token, t_llm_done, t_insert_done` + prompt version + providers + outcome (no body text). Local aggregation only in Phase 1.

## Success metrics — Phase 1 exit gate (Design §1.4, §12.2)

- Insertion success ≥99% (incl. fallbacks); text-loss incidents = 0
- E2E P50 ≤1.5s / P95 ≤3.0s (standard utterances)
- 2 consecutive weeks of daily "can't work without it" dogfooding; crashes/hangs 0 per week

## Conventions

- Language: code identifiers/comments English or Japanese OK; commits Conventional Commits in English; branches `<type>/<kebab-slug>` from `main`.
- Numeric constants from the design (100ms paste pre-delay, 300ms clipboard restore wait, 500-char chunk threshold, 0.3s misfire, timeouts) live in one constants file, each annotated `[tune in Phase 0]` where applicable.
- Prompt templates are versioned assets in-repo (semver + content hash), bundled into the app in Phase 1; every dictation event records the prompt version.
- Bundle ID and Developer ID signing identity are fixed forever once chosen (TCC grants are tied to them).
