# Contributing to Resecta

Thanks for your interest in contributing. This document covers the workflow, commit conventions, and audit gates that keep the codebase in line with the project's privacy and legal posture.

## Project organization

Resecta is open-source and AI-assisted. External contributors file a PR against `main` and the maintainer routes it.

- **App target:** `Sources/ResectaApp/` — iOS 26, Swift 6.2, MainActor default.
- **Engine package:** `Packages/RedactionEngine/` — SPM library, non-MainActor with `@concurrent`, Swift 6.2 strict concurrency. Import-friendly for non-app consumers.

## Setup

After cloning the repo:

```sh
./Scripts/install-hooks.sh   # symlink the pre-commit (audit-lint) and pre-push (batched tests) hooks
./regenerate.sh              # generate ResectaApp.xcodeproj from project.yml
```

The pre-commit hook lives at `.git/hooks/pre-commit` as a symlink to `Scripts/audit-lint.sh`. Re-run `install-hooks.sh` after a fresh clone if the symlink is missing. Never bypass the hook with `--no-verify`.

After adding new Swift files to `Sources/`, run `./regenerate.sh` to refresh the project. `project.pbxproj` is generated; do not edit it by hand.

## Branch model

- **`main`** — the line shipped to users.
- **`feat/<topic>`** — feature work.
- **`refactor/<topic>-YYYY-MM`** — in-flight refactor chains.
- **`fix/<topic>`** — bug fixes.

Push to your branch, then open a pull request against `main`.

## Commit format

Commit subjects describe the **mechanism** the change introduces, not the outcome it produces. Use verbs like `add`, `extend`, `create`, `seed`, `amend`, `cite`. Keep the subject under 72 characters.

```
extend README with threat model and quickstart

[body explaining the why]

Audit:
- [x] Mechanism-description language (per M-1)
- [x] Zero networking imports (per M-3)
- [x] No @AppStorage in @Observable (per M-4)
- [x] No PKCanvasView, no PDFPage.draw() (per M-5)
- [x] LOC ceilings respected (per M-6)
- [x] New strings use mechanism-description language (per M-8)
- [x] Spec edited if contract-touching (per M-9)
- [x] Tests pass: ResectaApp + RedactionEngine on iPhone 17 sim (per M-10)
- [x] Privacy floor: no document-derived data persisted (per M-11)
- [x] No new dependencies (per M-12)
- [x] No plan-first change without an agreed plan (per M-13)

Signed-off-by: Your Name <you@example.com>
```

The `Audit:` block is required. Each item is explicitly checked; the pre-commit hook enforces the mechanical items, and the rest are session discipline. The condensed block above is sufficient for external contributors.

## DCO sign-off

Every commit must include a `Signed-off-by:` line. By signing off, you certify that the contribution can be made under the project's license per the [Developer Certificate of Origin 1.1](https://developercertificate.org/).

The easiest way to add the line is the `-s` flag:

```sh
git commit -s -m "your message"
```

Resecta does not use a Contributor License Agreement (CLA); DCO is the contribution model.

## Audit checklist

The audit checklist has two halves: mechanical checks the local pre-commit hook runs automatically, and manual checks that sessions self-verify before each commit. The local pre-commit hook is the developer gate; the pull-request gate on GitHub Actions (`.github/workflows/ci.yml`) re-runs the same mechanical checks over the lines a pull request adds (`Scripts/audit-lint.sh --range base..HEAD`), alongside the claims lint, the app and test-bundle builds and the shipped-asset hash fence, and must be green before a merge to `main`. Everything else is session discipline plus the local test runs in the "Tests" section below.

### Mechanical checks (hook-enforced, local)

The hook (`Scripts/audit-lint.sh`) runs on every commit and blocks the commit on:

- **M-1.** Forbidden-token matches in staged `.swift`, `.xcstrings`, or `.md` diff lines. The regex pattern lives in `Scripts/audit-lint.sh`; the rules are summarized in the "Mechanism-description language" section below. Override on the same line with `LegalPhrases:safe` only when a legitimate Swift control-flow keyword is the trigger (rare).
- **M-3.** Banned networking symbols in `Sources/` or `Packages/`. Override with `Networking:exempt SafariView` on the same line for SafariView-adjacent helpers.
- **M-4.** `@AppStorage` declarations inside `@Observable` class bodies.
- **M-5.** Banned APIs (`PKCanvasView`, `PDFPage.draw`).
- **M-6.** LOC ceilings: 1500 on `Sources/ResectaApp/Views/SearchAndRedactSheet.swift`; 700 on any newly-added Swift file.

### Manual checks (session discipline)

- **M-2.** `.privacySensitive()` on views that render document-derived text.
- **M-8.** New strings use mechanism-description language (see below); classifications listed in the commit body.
- **M-9.** When a change touches a documented contract, the contract description and the code change land in the same commit.
- **M-10.** Test suites pass on the iPhone 17 simulator (both schemes).
- **M-11.** Privacy floor: no document-derived data persisted.
- **M-12.** No new dependencies (even Apple-first-party beyond the current set).
- **M-13.** No plan-first change without an agreed plan (see "Changes that need an agreed plan" below).
- Documented counts: `Scripts/doc-metrics.sh --check` passes whenever a change moves the line or test counts that README.md and ENGINEERING.md quote.

## Mechanism-description language

User-facing strings, doc comments, and commit messages describe what the code does (the mechanism), not what the user experiences (the outcome). Outcome claims create express warranty risk.

The rules cover six claim categories — security, technical architecture, comparative, use-case, AI-preparation, and feature — each pairing an unsafe phrasing with a mechanism-description rewrite. Read this section before adding user-facing strings; the pre-commit hook is the mechanical floor, and a manual review pass is required for borderline cases.

When a legitimate Swift control-flow keyword triggers M-1 (typical case is a `do { try ... }` error-handling block), add `LegalPhrases:safe` as a trailing comment on the same line. The override is rare; if it appears more than a few times in a single change, the language is probably drifting and needs a rewrite.

## Changes that need an agreed plan

The following changes land only after a written plan — the change, the reason, and how it will be verified — has been proposed and the maintainer has agreed to it; the edit follows the agreement, not the other way round:

- Any change to the `Phase` enum or transition table.
- Any modification to the `PipelineError` type hierarchy.
- Any new dependency (even Apple-first-party beyond the current set).
- Any change to legal or marketing language (including `Legal.xcstrings`, the EULA, and the privacy policy).
- Any change to the privacy manifest.
- Any uncertainty about whether existing code matches the spec.

If a PR crosses one of these, mark it as draft and open an issue that states the plan so the maintainer can agree to it before the edit lands.

This list is the canonical source for all contributors, including AI-assisted ones.

## Security

Vulnerability disclosure goes through [`SECURITY.md`](./SECURITY.md), not the public issue tracker. The file lists a dedicated disclosure address plus the GitHub Security Advisories channel, along with the safe-harbor policy and coordinated-disclosure timeline.

## Tests

Tests run locally before opening a PR and before any merge to `main`: the pre-push hook runs both suites through the batched runner, and the pull-request gate builds the app and both test bundles without running them. The full suites also run on GitHub Actions on demand and on release tags — `engine-suite.yml` (the engine package on the macOS host; `FileProtectionTests` is skipped there because a macOS host filesystem cannot exercise the iOS file-protection classes, which the simulator suite covers) and `sim-suite.yml` (the batched app suite on a hosted simulator) — neither is required for a merge. The two suites:

- `ResectaApp` — app-target tests, on the iPhone 17 simulator via the batched runner.
- `RedactionEngine` — engine package tests, via SwiftPM on the Mac host.

Run both:

```sh
Scripts/test-batched.sh ResectaApp
cd Packages/RedactionEngine && swift test --no-parallel
```

The batched runner builds once, then runs the app suites in serial batches (performance-budget suites run separately, report-only) to avoid simulator parallel-run flakiness — do not substitute a full-parallel `xcodebuild test` pass. It prints one `state=… tests=… passed=… failed=…` line per batch and ends with a `VERDICT:` line: `PASS` (exit 0) when no gating suite is red, `FAIL` (exit 1) listing the offending suites, or `INCOMPLETE` (exit 2) when an invocation had to be killed and its suites went unverified — re-run those. Full logs and per-batch `.xcresult` bundles land under `/tmp/test-batched-ResectaApp-<timestamp>/`. The engine run is serial by design (`--no-parallel`) and must end in a passing `Test run with N tests …` summary with exit 0.

The pre-push hook that `install-hooks.sh` installs runs both schemes on the simulator through the same batched runner before any push and blocks the push on a gating red (exit 1) or an incomplete run (exit 2); `SKIP_TESTS=1 git push` skips the gate and logs the skip to stderr.

Name and search tests exercise the system on-device name-recognition model (`NLTagger` `.nameType`), delivered as an on-demand OS asset. For the app suites, use a current iOS 26.x simulator runtime where that model is present (the runner picks an available iPhone 17 simulator automatically); where the asset has not downloaded, those tests skip or report different counts rather than failing the build.

## Questions

- Build or test issues: open a GitHub issue.
- Security disclosures: see [`SECURITY.md`](./SECURITY.md).
- Conduct or other concerns: route through the security disclosure address listed in [`SECURITY.md`](./SECURITY.md) until a separate channel is published.
