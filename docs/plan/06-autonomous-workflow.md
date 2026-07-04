# Autonomous Development Workflow

Premise: **the owner does not review code** (outside their capability). Quality is enforced by (1) automated gates, (2) Claude Code self-review, (3) owner product-QA by *using* the app — never by reading diffs. Claude Code implements, reviews, merges, and tracks progress autonomously within the escalation rules below.

## Roles

| Who | Does | Never asked to do |
| --- | --- | --- |
| Claude Code | Implementation, tests, self-review, PR + merge, STATUS/decision-log upkeep, prompting the owner at defined checkpoints | Spend money, accept ToS, choose permanent identifiers alone |
| Owner | Product QA (dogfooding + click-through checklists in Japanese), TCC permission dialogs, accounts/billing/ToS, product-taste decisions, triggering `/code-review ultra` | Code review, reading diffs |

## Session protocol (every implementation session)

1. Read `docs/plan/STATUS.md`, `00-overview.md`, and the active milestone file. STATUS.md is the single source of truth for progress across sessions.
2. Pick the first unblocked task in STATUS order; mark it `in-progress`.
3. Run the task lifecycle below. If a session ends mid-task, commit WIP to the task branch (`wip:` prefix) and note the exact stopping point in STATUS.md.
4. Never leave STATUS.md stale at session end.

## Task lifecycle (one task = one branch = one PR)

1. **Branch** from `main`: `<type>/<task-id>-<slug>` (e.g. `feat/m1-t1-state-machine`).
2. **Research first**: before writing adapter/library code (Speechmatics, Deepgram, Soniox, Gemini, Bedrock, GRDB, Sparkle, KeyboardShortcuts), fetch current docs via the context7 MCP; use the claude-api skill for anything touching Claude/Bedrock. Training data is stale for 2026 APIs.
3. **Implement** to the task's acceptance criteria (the contract). Deviations from the plan spec are allowed but must update the plan doc in the same PR and be logged in `docs/decisions.md`.
4. **Local gates** (all must pass before PR): `xcodebuild build` + `xcodebuild test`; golden-set harness when prompts change; invariant checks (see below).
5. **Self-review**: run `/code-review` on the diff — medium effort for ordinary tasks, **high for reliability-critical code** (TextInserter, HotkeyManager, DictationSession, anything touching invariants 1–8 in `00-overview.md`). Fix confirmed findings before opening the PR.
6. **Runtime verification**: run `/verify` — drive the affected flow, not just tests. Anything unverifiable without a human (TCC dialogs, pasting into third-party apps) goes into the PR's "Deferred manual QA" section as concrete steps in Japanese.
7. **PR** via `gh` CLI (GitHub MCP as fallback), base `main`, using `.github/PULL_REQUEST_TEMPLATE.md`. Body must show per-criterion evidence: test name, measured value, or `deferred → manual QA`.
8. **Merge** with a merge commit (no squash) once CI is green and self-review is clean. Delete the branch. Claude is authorized to merge (CLAUDE.md).
9. **Update** STATUS.md in the same PR.

Docs-only changes may commit directly to `main` (no PR).

## Quality gates (what replaces human review)

1. **Acceptance criteria as contract** — every plan task has verifiable criteria; the PR template forces evidence per criterion.
2. **CI** (`.github/workflows/ci.yml`, created in M0-T1): macOS arm64 runner; `xcodebuild build` + unit tests; invariant guards:
   - grep: no `os_log` / `print` / `NSLog` outside the `Log` wrapper (invariant 4)
   - grep: no API-key-like writes to UserDefaults (invariant 5)
   - unit test: Deepgram adapter request always contains `mip_opt_out=true` (invariant 7)
   - unit test: secure-input preflight aborts with zero clipboard writes (invariant 3)
   - CI stays **keyless**: no provider API keys in GitHub secrets. Keyed integration tests and the golden-set run execute locally pre-merge; results are pasted into the PR body.
3. **Per-task self-review** (`/code-review`, step 5 above) + **`/verify`** (step 6).
4. **Milestone deep review**: the owner triggers `/code-review ultra` (billed, cloud multi-agent) — required after M5 (insertion) and M6 (formatting), and before the Phase 1 exit gate; `/security-review` before any external distribution (Phase 2). Claude cannot launch these itself — it must explicitly prompt the owner with the exact command to type when a milestone completes.
5. **Owner QA checklists**: at each milestone completion, Claude writes a 5–10 item click-through checklist in plain Japanese (no code knowledge needed, e.g. 「Slackの入力欄にフォーカスして Fn を押しながら話す → 整形された文が入る」), files it in the milestone PR, and the owner reports pass/fail in conversation. Dogfooding metrics (M10-T2 stats view) are the Phase 1 gate evidence.
6. **Decision log** (`docs/decisions.md`): dated one-liners for every non-obvious choice (library, workaround, spec deviation). This is the audit trail a reviewer would otherwise provide.

## Escalation rules — stop and ask the owner ONLY for:

- Money / accounts / ToS: creating provider accounts, accepting terms, any spend (API budgets, Apple Developer Program)
- Sending user data to any new third party; privacy-policy-relevant behavior changes
- Phase-gate No-Go outcomes (Phase 0 gates, Phase 1 exit) and scope changes
- Permanent identifiers: bundle ID, signing identity, product rename
- Destructive/irreversible ops on the repo or the owner's machine

Everything else (module structure, naming, minor spec ambiguities, test strategy): decide, log in `docs/decisions.md`, proceed. Blocked-on-owner tasks are marked `blocked(owner)` in STATUS.md and skipped, not waited on.

## GitHub conventions (extends CLAUDE.md)

- PR title = conventional-commit style including the task ID: `feat(m5): M5-T2 paste simulation path`
- Merge commits only (no squash) — preserves in-branch history for later audit
- No GitHub Issues (solo repo; STATUS.md avoids dual tracking). GitHub milestones/labels not used.
- Tags at gates: `phase0-complete`, `m5-complete`, `phase1-exit` — rollback/reference points
- CI must be green on `main` at all times; a red `main` is the top-priority task in any session

## Tooling map

| Tool | When |
| --- | --- |
| `gh` CLI (fallback: GitHub MCP tools) | PR create/merge, CI status (`gh run watch`) |
| context7 MCP | Current provider/library docs before any adapter work |
| claude-api skill | Claude/Bedrock adapter work, model IDs, pricing |
| `/code-review` | Per task, pre-PR (medium; high for critical modules) |
| `/verify` | Per task with runtime surface |
| `/code-review ultra` | Owner-triggered per milestone (M5, M6, Phase 1 exit) |
| `/security-review` | Owner-triggered before Phase 2 distribution |

## Owner's standing (non-code) task list

Tracked as `blocked(owner)` rows in STATUS.md when they gate work:

1. One-time: `gh auth login` (type `! gh auth login` in a Claude Code session)
2. Provider accounts + API keys for Phase 0: Speechmatics, Deepgram, Soniox, Google AI (Gemini paid tier), AWS (Bedrock Tokyo) — Claude drafts signup steps and handles key storage (Keychain) once keys exist
3. Click TCC dialogs (mic / Accessibility) when local testing starts
4. Record the S2 utterance set (their own voice, ~100 short clips; Claude prepares the script list)
5. Per milestone: run the Japanese QA checklist; type `/code-review ultra` when prompted
6. Phase 1: daily dogfooding (email/Slack/Claude Code) — this IS the QA
7. Phase 2 (later): Apple Developer Program, Speechmatics ToS written confirmation
