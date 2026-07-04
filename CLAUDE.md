# CLAUDE.md

Think in English; respond to the user in Japanese.

## Autonomous Development Protocol

The owner does not review code — quality is enforced mechanically. Full spec: `docs/plan/06-autonomous-workflow.md`. Non-negotiables:

- Session start (implementation work): read `docs/plan/STATUS.md` and continue the first unblocked task. Keep STATUS.md current in the same PR as the work.
- One task = one branch = one PR. Before merging: local build+tests green, `/code-review` on the diff (high effort for TextInserter / HotkeyManager / DictationSession / invariant-touching code), `/verify` where a runtime surface exists.
- Claude merges its own PRs (merge commit) once CI is green. A red `main` is the top-priority task in any session.
- Escalate to the owner ONLY for: money/accounts/ToS, new third-party data recipients, phase-gate No-Go, permanent identifiers (bundle ID / signing identity), destructive ops. Everything else: decide, log one line in `docs/decisions.md`, proceed.
- At milestone completion, prompt the owner with the exact command to run (`/code-review ultra`, QA checklist) — Claude cannot trigger those itself.
- Before adapter/library work, fetch current docs (context7 MCP; claude-api skill for Claude/Bedrock). Product invariants live in `docs/plan/00-overview.md` and are acceptance criteria, not suggestions.

## GitHub Guidelines

### Commit Messages (Conventional Commits, English)

Claude Code commits at appropriate levels of granularity.
Write concisely in English. 1 to 2 lines are sufficient.

### Branches

- Branch from `main` and name them using the format `<type>/<kebab-slug>` (type: `feat` / `fix` / `chore` / `docs` / `refactor`). The base is always `main`.
- Claude Code may create branches at appropriate granularities and is also authorized to merge them.

### PR / Merging

- Create PRs using the `gh` CLI, with `main` as the base.
- Use merge commits instead of squash merging (to keep the commit history within the branch).
- Ensure the project's local gates pass before submitting a PR (this repo: `xcodebuild build` + `xcodebuild test`; plus the golden-set harness for prompt changes).
- PR title includes the plan task ID (e.g. `feat(m5): M5-T2 paste simulation path`); PR body follows `.github/PULL_REQUEST_TEMPLATE.md` with per-criterion acceptance evidence.

## Security

- Creating or editing `.env` / `.env.local` is permitted (provided that sensitive values are managed appropriately in production). `.env*` files are already included in `.gitignore`.
- If necessary, you may also handle private keys, `id_rsa`, `.pem`, `.key`, `wallet.json`, keystores, etc.
- For services like Supabase or Stripe, Claude Code should perform operations via the CLI as a proxy whenever possible. Claude Code should also handle the acquisition and configuration of API keys as much as possible.
