# Contributing to Resecta

Resecta is maintained by one person and does not expect outside contributions in the near term; issues are welcome. This file records the gates every change passes and where each gate lives, so a reader can check that they exist.

## Setup

```sh
git clone https://github.com/Merlin1A/resecta.git && cd resecta
./Scripts/install-hooks.sh   # pre-commit = Scripts/audit-lint.sh (by symlink); pre-push = both test schemes
./regenerate.sh              # ResectaApp.xcodeproj from project.yml via XcodeGen
```

`project.pbxproj` is generated — never edit it by hand; re-run `./regenerate.sh` after adding Swift files. Never bypass a hook with `--no-verify`. Changes land on `main` through pull requests; releases are tagged from it.

## What every change passes

1. **The pre-commit hook** (`Scripts/audit-lint.sh`) runs the mechanical checks on the staged change; it does not read the commit message. Its rules: mechanism-description language on added Swift, string-catalog and Markdown lines (M-1); the banned networking symbols on added Swift source lines (M-3); no `@AppStorage` inside an `@Observable` class (M-4); the two banned APIs, `PKCanvasView` and `PDFPage.draw` (M-5); and the LOC ceilings — 1,500 lines on `Sources/ResectaApp/Views/SearchAndRedactSheet.swift`, 700 on any newly added Swift file (M-6). The script's own six checks: a staged `project.yml` change needs a regenerated project (AL-1); a new entry in the app target's `resources:` block is reported as a warning, because that block enumerates nothing (AL-2); the app-bundle sample statement and the engine's fixture copy stay byte-identical (AL-3), and so do the two loan-packet copies (AL-4); a test that returns before its first assertion is reported on the lines a commit adds (AL-5); and a token in the shape of a private planning identifier is refused on added Swift and string-catalog lines (AL-6). The check ids appear in the hook's messages; the rules and their override markers (`LegalPhrases:safe`, `Networking:exempt`, `SilentGuard:ok`, `Shorthand:ok`) are documented at the top of the script.
2. **The pre-push hook** runs both test schemes through `Scripts/test-batched.sh` on the simulator and blocks the push on a gating red (exit 1) or an incomplete run (exit 2); `SKIP_TESTS=1 git push` skips the gate and logs the skip to stderr.
3. **The pull-request gate** (`ci.yml`, the `pr-gate` check required on `main`) builds the app and its unit- and UI-test bundles without running them, runs the audit lint over the lines the change adds and the claims lint over the shipping docs (both from the base branch's copies of the scripts), checks the documented counts (`Scripts/doc-metrics.sh --check`) and the shipped-asset hashes, and fails if a source file already over 800 lines grows (`Scripts/growth-ratchet.sh`: a file that size is split along a seam, not extended — a no-growth rule on large existing files, distinct from M-6's hard caps on new files).
4. **The hosted suites.** `sim-suite.yml` runs the app's unit suite on a hosted iPhone 17 simulator for every pull request to `main`, as a non-required check; it runs both schemes through the batched runner every Monday and on `v*` tag pushes, and one chosen scheme on manual dispatch (GitHub disables the schedule after sixty days without repository activity). `engine-suite.yml` runs the engine package with `swift test` on the macOS host on manual dispatch only and has not yet reached a verdict on the hosted runner.

Alongside the hooks, every change keeps three floors: tests green on the iPhone 17 simulator for both schemes; no document-derived data persisted; no new dependency, not even an Apple one beyond the current set.

## Running the tests

```sh
TEST_BATCHED_SIM_UDID=<simulator udid> Scripts/test-batched.sh ResectaApp
cd Packages/RedactionEngine && swift test --no-parallel --skip FileProtectionTests
```

`TEST_BATCHED_SIM_UDID` is required — it pins the simulator by id and the runner exits 2 without it; export it before pushing. The batched runner builds once, then runs the suites in serial batches (performance-budget suites run alone, report-only, and eight suites on the script's exclusion list never gate) to avoid simulator parallel-run flakiness — do not substitute a full-parallel `xcodebuild test` pass. It prints one `state=… tests=… passed=… failed=… skipped=… known-issues=…` line per batch and ends with a `VERDICT:` line: `PASS` (exit 0), `FAIL` (exit 1) listing the offending suites, or `INCOMPLETE` (exit 2) when an invocation had to be killed and its suites went unverified — re-run those. Logs and per-batch `.xcresult` bundles land under `/tmp/test-batched-<scheme>-<stamp>/`.

The engine run is serial by design (`--no-parallel`). `FileProtectionTests` needs the iOS file-protection classes, which a macOS host filesystem cannot exercise; the simulator suite covers it (the pre-push hook runs the engine scheme there).

Name and search tests exercise the system on-device name-recognition model (`NLTagger` `.nameType`), delivered as an on-demand OS asset. Use a current iOS 26.x simulator runtime where that model is present; where the asset has not downloaded, those tests skip or report different counts rather than failing the build.

## Changes that need an agreed plan

The following land only after a written plan — the change, the reason, and how it will be verified — has been proposed and the maintainer has agreed to it; the edit follows the agreement, not the other way round:

- Any change to the `Phase` enum or transition table.
- Any modification to the `PipelineError` type hierarchy.
- Any new dependency (even Apple-first-party beyond the current set).
- Any new third-party GitHub Action: its `patterns_allowed` entry goes into the repository's Actions settings before the pull request that uses it, and it is pinned to a full commit SHA (the repository setting requires it), or the workflow fails at startup.
- Any change to legal or marketing language (including `Legal.xcstrings`, the EULA, and the privacy policy).
- Any change to the privacy manifest.
- Any uncertainty about whether existing code matches the spec.

If a pull request crosses one of these, mark it as draft and open an issue that states the plan so the maintainer can agree to it before the edit lands. When a change touches a documented contract, the contract description and the code change land in the same commit.

## Mechanism-description language

User-facing strings, doc comments, and commit messages describe what the code does (the mechanism), not what the user experiences (the outcome); outcome claims create express-warranty risk. The pre-commit hook is the floor and a human read is the bar. `LegalPhrases:safe` (a trailing comment on the line; `<!-- LegalPhrases:safe -->` in Markdown) is for prose that has to use one of the listed words, and it is rare: if it appears more than a few times in one change, the language is drifting and needs a rewrite.

## Sign-off and licence

Contributions from outside the project carry a `Signed-off-by:` line on every commit (`git commit -s`), certifying the [Developer Certificate of Origin 1.1](https://developercertificate.org/); no check enforces it. The project is licensed under Apache-2.0 and uses no Contributor License Agreement.

## Security and conduct

Vulnerability disclosure goes through [`SECURITY.md`](./SECURITY.md), not the public issue tracker. Conduct: [`CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md).
