# Decision log

Audit trail replacing human code review (see `docs/plan/06-autonomous-workflow.md`). One dated entry per non-obvious decision: what was decided, why, alternatives rejected. Newest first.

## 2026-07-04

- **Autonomous workflow adopted**: owner does not review code; quality = CI invariant guards + per-task `/code-review`+`/verify` + owner-triggered `/code-review ultra` per milestone + owner QA checklists in Japanese. Progress tracked in `docs/plan/STATUS.md`, not GitHub Issues (solo repo, avoid dual tracking).
- **CI kept keyless**: provider API keys never stored as GitHub secrets; keyed integration/golden-set tests run locally pre-merge with results pasted into the PR. Rationale: minimize key exposure surface; CI value is build+unit+invariant greps.
- **Plan docs created** (`docs/plan/00–06`): English for token efficiency per owner instruction; task-level acceptance criteria serve as the review contract.
