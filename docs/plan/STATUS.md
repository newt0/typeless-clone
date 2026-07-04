# STATUS — single source of truth for progress

Protocol: see `06-autonomous-workflow.md`. Statuses: `todo` / `in-progress` / `pr(#N)` / `done` / `blocked(<what>)`. Order = execution order; pick the first unblocked `todo`. Update this file in the same PR as the work.

## Now

Environment resolved: **Xcode 26.6 installed, `gh` authenticated, autonomous PR flow proven** (PR #1 merged via CI-green → merge commit). Full test suite runs with `./scripts/test.sh`.

- **PR #1 (merged)**: SwiftPM package (`KoeKit`/`KoeCore`), Constants, `DictationSession` state machine (M1-T1), CI, scripts.
- **M1-T2** (this branch): `InsertionSerializer` FIFO gate + `SessionCoordinator` + collaborator seams; 18 tests total green.

Bundle ID fixed: **`dev.newt.Koe`**. The app is a runnable menu-bar skeleton (PR #3).

**Running the app** (owner QA): `xcodegen generate` (once, or after `project.yml` changes) → open `Koe.xcodeproj` in Xcode → Run. Or `open` the built `Koe.app`. It shows a mic icon in the menu bar with History/Settings/Pause/Quit; no dictation yet. `Koe.xcodeproj` is git-ignored (regenerate from `project.yml`). Requires `brew install xcodegen`.

Package has two library targets: **KoeCore** (pure) + **KoeStorage** (GRDB). Storage layer done (History M7-T1, Dictionary M8-T1). Remaining solo-buildable work is now app-UI/runtime: M7-T2 history UI, M9 HUD, M10 settings, M2/M3 hotkey+audio, M5-T2 paste — all need app-target wiring (and owner QA for TCC/insertion). Provider work (M4/M6-T1/S2/S3) needs owner API keys.

## Phase 0 spikes (`01-phase0-spikes.md`)

| Task | Status | Notes |
| --- | --- | --- |
| S1-T1 insertion harness | todo | Needs Accessibility TCC grant at first run (owner clicks dialog) |
| S1-T2 insertion matrix run | todo | Depends S1-T1; partially manual (owner assists per checklist) |
| S2-T1 STT harness + utterance set | blocked(owner: STT API keys, voice recordings) | |
| S2-T2 STT A/B evaluation | todo | Depends S2-T1 |
| S3-T1 golden set v1 | todo | No keys needed to author cases — can start anytime |
| S3-T2 regression harness + LLM A/B | blocked(owner: Gemini/AWS keys) | Harness code can be written before keys |
| S4-T1 E2E latency prototype | todo | Depends S1/S2/S3 outcomes |

## Phase 1 — M0–M3 (`02-phase1-m1-core.md`)

| Task | Status | Notes |
| --- | --- | --- |
| M0-T1 Xcode project + layout + CI | done | SwiftPM pkg + CI (PR #1); Xcode app target via XcodeGen, bundle ID `dev.newt.Koe` (PR #3) |
| M0-T2 status item, Log wrapper, Keychain | done(branch) | `feat/m0-t2-app-shell`: NSStatusItem menu-bar app, Log (StaticString, invariant 4), SecretStore/Keychain; runnable |
| M1-T1 DictationSession actor | done | merged PR #1, 11 tests |
| M1-T2 coordinator + FIFO insertion lock | done | merged PR #2, +7 tests |
| M2-T1 CGEventTap Fn hotkey | todo | |
| M2-T2 tap liveness + alt hotkey | todo | |
| M3-T1 audio engine + buffer | todo | |
| M3-T2 device-switch survival | todo | |

## Phase 1 — M4–M6 (`03-phase1-m2-pipeline.md`)

| Task | Status | Notes |
| --- | --- | --- |
| M4-T1 STTClient protocol | todo | |
| M4-T2 primary STT adapter | blocked(S2 decision) | |
| M4-T3 batch resend + retry UI | todo | Depends M4-T2 |
| M5-T1 preflight / ContextProvider | done(branch) | `feat/m5-t1-preflight`, +7 tests; pure decision (secure→block no-clipboard, app-changed→hold). AX/IsSecureEventInput reads are the M5-T2 runtime part |
| M5-T2 paste simulation path 1 | todo | |
| M5-T3 paths 2–3 + per-app overrides | todo | Milestone end → prompt owner: `/code-review ultra` |
| M6-T1 LLMClient protocol + adapters | blocked(S3 decision) | Adapter needs provider choice + keys |
| M6-T2 prompt assembly (versioned) | done(branch) | `feat/m6-t2-prompt-assembly`, +9 tests; template v1.0.0 (ja), content-hash versioning, injection boundary |
| M6-T3 chunking/validation/degradation | done(branch) | `feat/m6-t3-chunk-validate`, +13 tests; chunker + OutputValidator (empty/summarization/leakage → degrade). Async retry/timeout ladder lands with M6-T1 |

## Phase 1 — M7–M11 (`04-phase1-m3-experience.md`)

| Task | Status | Notes |
| --- | --- | --- |
| M7-T1 history schema + write-ahead | done(branch) | `feat/m7-t1-history-store`, +8 tests; GRDB in new KoeStorage target; write-ahead + FTS5 trigram + LIKE fallback for short JP queries + retention |
| M7-T2 history UI | todo | |
| M8-T1 dictionary store + dual feed | done(branch) | `feat/m8-t1-dictionary-store`, +9 tests; GRDB CRUD + dual serializers (LLM prompt entries / STT vocab). Editor UI is M10/settings |
| M9-T1 HUD panel | todo | |
| M10-T1 settings | todo | |
| M10-T2 metrics pipeline | todo | |
| M11-T1 onboarding flow | todo | |
| M11-T2 permission revocation handling | todo | |
| Phase 1 exit gate | todo | Owner: 2-week dogfood + `/code-review ultra` + checklist in `04` |

## Owner-blocked items

Owner-facing step-by-step guide (Japanese): **`docs/owner-guide.md`**.

- [x] Install Xcode (26.6) + `xcode-select`
- [x] `gh auth login`
- [x] Bundle ID decided: `dev.newt.Koe`
- [ ] **[critical path] API keys: Gemini (paid tier) + Speechmatics** → stored in Keychain (`security add-generic-password -s dev.newt.Koe -a geminiAPIKey/speechmaticsAPIKey`). Unblocks M4/M6-T1 and the first vertical slice.
- [ ] Phase 0 A/B keys (later): Deepgram / Soniox / AWS Bedrock (Tokyo)
- [ ] S2 utterance recordings (~100 clips; script list provided by Claude on request)
