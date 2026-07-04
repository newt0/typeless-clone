# Decision log

Audit trail replacing human code review (see `docs/plan/06-autonomous-workflow.md`). One dated entry per non-obvious decision: what was decided, why, alternatives rejected. Newest first.

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
