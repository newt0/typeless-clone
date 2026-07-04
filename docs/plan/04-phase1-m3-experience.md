# Phase 1 — Milestones M7–M11 (history, dictionary, HUD, settings, onboarding)

Prereq reading: `00-overview.md`. M7 should land early (M6/M5 reference `HistoryWriting`); M9–M11 polish the experience and close Phase 1.

## M7 — HistoryStore (write-ahead, FTS5)

### M7-T1 Schema + write-ahead writes

- GRDB database at `~/Library/Application Support/Koe/` (FileVault assumed; no app-level encryption). Table `dictations(id, created_at, raw_text, formatted_text, app_bundle_id, insert_result, prompt_version, latency_ms, feedback, …)` + FTS5 index over raw/formatted text (Japanese tokenization — verify FTS5 config works for JA queries).
- **Write-ahead protocol (invariant 1)**: (1) INSERT row the moment the final transcript arrives (raw text, timestamp, frontmost app); (2) UPDATE with formatted text on formatting completion; (3) UPDATE with insert result (success / fallback stage / failure). A crash at any stage leaves at least the raw transcript recoverable.
- Migrations via GRDB's migrator from day one.
- Acceptance: unit tests for the 3-stage write; kill the process between stages → row survives with the data written so far; FTS5 finds Japanese substrings.
- Design ref: §7.7, §10.1.
- Depends: M1-T2 (called from the session pipeline).

### M7-T2 History UI

- Window (SwiftUI) from the status-item menu: reverse-chronological list, full-text search box, per-row: formatted (and raw on expand), timestamp, target app, insert result badge; actions: copy, delete, 👎 feedback (stored in `feedback`, used as the rework-rate proxy metric).
- Retention settings hook: delete-all, auto-delete after N days (executed on launch).
- Acceptance: search/copy/delete/👎 work; deleted rows also leave the FTS index.
- Design ref: §1.4 (metrics), §5.5, §9.3.
- Depends: M7-T1, M10-T1 (settings).

## M8 — DictionaryStore

### M8-T1 Store + dual feed

- GRDB table `dictionary(id, surface, reading, notes, created_at)`. CRUD + simple editor UI (list, add, edit, delete) reachable from settings.
- Single source feeding both consumers: STT keyword boost (M4-T2, adapter-specific format, e.g. Speechmatics `sounds_like` in full-width kana from `reading`) and LLM prompt block [4] (M6-T2).
- Acceptance: adding a term changes both the STT session config (next session) and the assembled prompt; unit test the two serializers.
- Design ref: §5.2 [4], §4.1 (FR-05).
- Depends: M4-T2, M6-T2.

## M9 — HUDController

### M9-T1 Non-activating panel

- `NSPanel` with `.nonactivatingPanel` (never becomes key — never steals focus or disturbs the target app's IME), `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `ignoresMouseEvents = true` by default (interactive only when showing action buttons like Retry).
- Position: bottom-center of the screen holding keyboard focus (no cursor following); content in SwiftUI hosted inside the panel, rendered purely from `DictationSession` observable state.
- States: recording (waveform + live partial transcript) → formatting (spinner/progress) → done (auto-dismiss after a few hundred ms) / error (reason + action button) / notices (device switch, fallback landing "Press ⌘V", secure-input refusal).
- Acceptance: manual — dictating into a focused text field never loses focus or IME composition state in the target app; HUD visible over full-screen apps; every pipeline notice from M3–M6 renders.
- Design ref: §7.5, §10.2.
- Depends: M1-T1.

## M10 — SettingsStore + instrumentation

### M10-T1 Settings

- UserDefaults-backed store + SwiftUI settings window: hotkey selection (Fn / alt combo via KeyboardShortcuts), style (auto / desu-masu / dearu), prefer-built-in-mic (default ON), LLM-failure behavior (insert raw [default] / clipboard only), per-app overrides (insertion path, extra delay), history retention, telemetry opt-out, launch-at-login toggle (`SMAppService.mainApp`).
- API keys UI writes to Keychain only (M0-T2).
- Acceptance: every setting round-trips and is consumed by its owning module; no key material in UserDefaults plist.
- Design ref: §7.7, §7.1 table.
- Depends: M0-T2.

### M10-T2 Metrics pipeline (local-only in Phase 1)

- Collect `DictationMetrics` (M1-T1 timestamps) + prompt version + provider names + outcome per dictation; **no body text** (invariant 4). Store locally (own GRDB table is fine).
- Settings window shows last-100 segment stats (P50/P95 per segment vs the budget table) — the dogfooding self-diagnosis view and the Phase 1 gate evidence.
- Rework-rate proxies: re-dictation into the same app within 30s; 👎 rate (M7-T2); ⌘Z within a short window after insert (observable via the existing event tap) — events only.
- Acceptance: after N test dictations the stats view matches raw rows; audit confirms no text columns.
- Design ref: §8.4, §5.5, §9.3.
- Depends: M1-T1, M7-T1.

## M11 — Onboarding + permission lifecycle

### M11-T1 6-step onboarding flow (target ≤3min, FR-07)

SwiftUI window, steps skippable (but app shows ⚠︎ state without steps 2–3), re-runnable from the menu ("Redo setup"):

1. **Welcome + privacy consent** (APPI): one screen naming the STT/LLM providers, their countries, "no training, history stays on this Mac"; explicit consent to proceed.
2. **Microphone**: standard TCC prompt; on denial → deep link to System Settings + re-check button.
3. **Accessibility** (hardest step): one diagram explaining why (hotkey + insertion); `AXIsProcessTrustedWithOptions` prompt + deep link; poll every 2s and auto-advance on grant; then try creating the event tap — if it fails (known post-grant quirk) show a "Restart and continue" button that resumes at this step.
4. **Hotkey**: default Fn hold; guide (screenshot + deep link) to set the globe key to "Do Nothing" (also resolves the macOS dictation Fn-double-tap conflict); "don't want to change it" → switch to alt hotkey ⌥Space.
5. **Test dictation**: in-app text field exercising the real pipeline (partials → formatting → insertion); success message "works the same in every app".
6. **Finish**: login-item opt-in (`SMAppService`), menu-bar icon tour.

- Acceptance: fresh macOS user account (or TCC reset via `tccutil`) completes to a successful test dictation in ≤3min; every denial path has a recovery.
- Design ref: §11.2, §9.2.
- Depends: M2, M3, M5, M6 (test dictation uses the real pipeline).

### M11-T2 Permission revocation detection + re-guidance

- Detectors: tap-disable events (M2-T2), 60s `AXIsProcessTrusted()` poll, mic permission check at record start, self-check at every launch (macOS updates can reset TCC).
- Behavior: status item switches to ⚠︎; clicking it (and pressing the hotkey while broken) shows a panel: what's broken + one-click deep link to the right settings pane. Silence is the worst failure mode — the hotkey must never appear simply dead.
- Acceptance: revoke Accessibility while running → ⚠︎ within 60s, hotkey press produces the panel, re-grant restores function without relaunch (or prompts restart if the tap can't revive).
- Design ref: §11.3, risk R7/R8.
- Depends: M2-T2, M11-T1.

## Phase 1 exit gate (before any distribution)

- [ ] Insertion success ≥99% incl. fallbacks; zero text-loss incidents (M10-T2 stats)
- [ ] E2E P50 ≤1.5s / P95 ≤3.0s standard utterances
- [ ] 2 weeks daily dogfooding (email/Slack/Claude Code); crashes/hangs 0 per week
- [ ] Golden-set regression green on the shipped prompt version
- [ ] Audit: no body text in logs/metrics; keys only in Keychain; builds with embedded keys never distributed
