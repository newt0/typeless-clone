# STATUS — single source of truth for progress

Protocol: see `06-autonomous-workflow.md`. Statuses: `todo` / `in-progress` / `pr(#N)` / `done` / `blocked(<what>)`. Order = execution order; pick the first unblocked `todo`. Update this file in the same PR as the work.

## Now

Next up: **M0-T1** (project bootstrap) and **S1-T1** (insertion harness) — both unblocked. S2/S3 are blocked on owner-provided API keys.

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
| M0-T1 Xcode project + layout + CI | todo | CI workflow file created here |
| M0-T2 status item, Log wrapper, Keychain | todo | |
| M1-T1 DictationSession actor | todo | |
| M1-T2 coordinator + FIFO insertion lock | todo | |
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
| M5-T1 preflight / ContextProvider | todo | Provider-independent — can run parallel to S2–S4 |
| M5-T2 paste simulation path 1 | todo | |
| M5-T3 paths 2–3 + per-app overrides | todo | Milestone end → prompt owner: `/code-review ultra` |
| M6-T1 LLMClient protocol + adapters | blocked(S3 decision) | |
| M6-T2 prompt assembly (versioned) | blocked(S3 golden set) | |
| M6-T3 chunking/validation/degradation | todo | Depends M6-T2; milestone end → `/code-review ultra` |

## Phase 1 — M7–M11 (`04-phase1-m3-experience.md`)

| Task | Status | Notes |
| --- | --- | --- |
| M7-T1 history schema + write-ahead | todo | Land early; M5/M6 reference HistoryWriting |
| M7-T2 history UI | todo | |
| M8-T1 dictionary store + dual feed | todo | |
| M9-T1 HUD panel | todo | |
| M10-T1 settings | todo | |
| M10-T2 metrics pipeline | todo | |
| M11-T1 onboarding flow | todo | |
| M11-T2 permission revocation handling | todo | |
| Phase 1 exit gate | todo | Owner: 2-week dogfood + `/code-review ultra` + checklist in `04` |

## Owner-blocked items (see workflow doc §Owner's standing task list)

- [ ] `gh auth login` (one-time)
- [ ] STT API keys: Speechmatics / Deepgram / Soniox
- [ ] LLM API keys: Google AI (Gemini paid tier) / AWS Bedrock (Tokyo)
- [ ] S2 utterance recordings (~100 clips; script list to be provided by Claude)
