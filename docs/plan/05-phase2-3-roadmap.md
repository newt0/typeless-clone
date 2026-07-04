# Phase 2–3 Roadmap (outline only — detail after Phase 1 gate)

Not task-ready by design: Phase 1 dogfooding will change details. Re-plan each phase when its predecessor's gate passes. Design refs: §2, §9, §12.

## Phase 2 — Distributable beta

Hard precondition: **no build containing API keys ever leaves the developer machine**; the relay must exist before the first external tester.

- **Relay server** (single thin service): streams audio→STT and prompts→LLM in memory only — zero persistence and no body/audio payloads in access logs; holds all provider API keys (secrets manager, documented rotation); device-token auth issued at registration (stored in client Keychain); per-device quota; kill switch; versioned prompt distribution (client fetches at launch + periodically, falls back to the bundled prompt). Client-agnostic API (future iOS/Web reuse). Provider failover behind the relay (simple circuit breaker: e.g. >50% errors in a 60s window → runner-up provider), no client changes needed.
- **Distribution**: Developer ID + Hardened Runtime + `notarytool` in CI; Sparkle 2 auto-update with EdDSA keys (offline backup), HTTPS appcast, stable/beta channels; CI asserts bundle ID + signing identity never change (TCC binding).
- **Crash reporting** decision (Sentry self-hosted or crash logs only) — stack traces only, zero body text.
- **Legal/privacy**: privacy policy naming providers/countries/retention (APPI cross-border consent already in onboarding step 1); resolve the Speechmatics ToS §10.3 training-license contradiction in writing (else switch to runner-up STT — A/B data makes this an immediate call); provider retention truth table re-checked quarterly; DPA collection.
- **Gate → Phase 3**: ≥50% of testers still using ≥3 days/week after 2 weeks; insertion ≥99% in external environments; crash-free sessions ≥99.5%; zero significant privacy/security findings.

## Phase 3 — P1 features (adopt/drop each by rework-rate + usage metrics)

Priority order: FR-08 per-app tone profiles (extends prompt block [3] via per-app context) → FR-11 style personalization → FR-09 Ask mode (voice=instruction + selected text=data; **separate prompt template** — never merged with dictate; per-use explicit consent before sending screen text) → FR-12 snippets → FR-10 translation. Plus: VAD auto-stop for toggle mode; speculative formatting (launch LLM on last partial at key-up, accept if final matches) if P50 exceeds target; network-outage buffering with post-recovery processing (NFR-06); crash-recovery re-processing of leftover audio temp files.
