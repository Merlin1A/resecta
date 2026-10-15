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

1. **The pre-commit hook** (`Scripts/audit-lint.sh`) runs the mechanical checks on the staged change; it does not read the commit message. Its rules: mechanism-description language on added Swift, string-catalog and Markdown lines (M-1); the banned networking symbols on added Swift source lines, and, on every run, the call-shaped networking and hand-off symbols anywhere in the shipping source against the sites pinned in the script (M-3); no `@AppStorage` inside an `@Observable` class (M-4); the two banned APIs, `PKCanvasView` and `PDFPage.draw` (M-5); and the LOC ceilings — 1,500 lines on `Sources/ResectaApp/Views/SearchAndRedactSheet.swift`, 700 on any newly added Swift file (M-6). The script's own five checks: a staged `project.yml` change needs a regenerated project (AL-1); a new entry in the app target's `resources:` block is reported as a warning, because that block enumerates nothing (AL-2); the app-bundle sample statement and the engine's fixture copy stay byte-identical (AL-3); a test that returns before its first assertion is refused on the lines a commit adds (AL-5); and a token in the shape of a private planning identifier — a register id, a section sign with no standard or repository document named on the line, a Markdown name the repository does not track, or, in a comment, a planning-process word, a step token or the maintainer's first name — is refused on added Swift and string-catalog lines (AL-6). The check ids appear in the hook's messages; the rules and their override markers (`LegalPhrases:safe`, `Networking:exempt SafariView`, `SilentGuard:ok`, `Shorthand:ok`) are documented in the script's comments.
2. **The pre-push hook** runs both test schemes through `Scripts/test-batched.sh` on the simulator and blocks the push on a gating red (exit 1) or an incomplete run (exit 2); `SKIP_TESTS=1 git push` skips the gate and logs the skip to stderr.
3. **The pull-request gate** (`ci.yml`, the `pr-gate` check required on `main`) builds the app and its unit- and UI-test bundles without running them, runs the audit lint over the lines the change adds and the claims lint over the shipping docs and the view layer's string literals (both from the base branch's copies of the scripts), checks the documented counts (`Scripts/doc-metrics.sh --check`, the logging counts among them) and the shipped-asset hashes with the manifest's Ed25519 signature (`Scripts/verify-shipped-asset-hashes.sh`), fails if a source or test file already over 800 lines grows (`Scripts/growth-ratchet.sh`, over the source trees and both test trees: a file that size is split along a seam, not extended — a no-growth rule on large existing files, distinct from M-6's hard caps on new files), and fails if the engine package's `public` and `open` declaration lines exceed the cap `Scripts/engine-public-surface-check.sh` carries, printing the count and the headroom left under the cap and under each release line cap; a pull request that adds such a declaration names it in its description with a line `ENGINE-PUBLIC +n: <the declarations>`, so every use of that headroom is visible at review. `CHANGELOG.md` carries git's union merge driver (`.gitattributes`), so two branches that each add lines under `[Unreleased]` merge without a conflict on them. Two further steps report without failing the check: a census of tests that can pass without asserting, and a run of the change's own copies of the lint scripts.
4. **The hosted suites.** `sim-suite.yml` runs the app's unit suite on a hosted iPhone 17 simulator for every pull request to `main`, as a non-required check; it runs both schemes through the batched runner every Monday and on `v*` tag pushes, and one chosen scheme on manual dispatch (GitHub disables the schedule after sixty days without repository activity). On the weekly and tag runs the ResectaApp job also runs the editor's link-policy UI tests (`DocumentLinkUITests`) against the bundles it built, and a failed weekly or tag run is reported by an error annotation, a step summary and, when the repository variable `NTFY_TOPIC` is set, a post to that ntfy topic. On the hosted runner the five suites whose verification pass, OCR sweep or OCR re-check hangs there (two app suites, three engine suites) are left out by name (`TEST_BATCHED_EXCLUDE`), listed in the job summary and counted in the verdict line; the pre-push hook runs every suite. The engine package has no separate host run: the simulator suite's engine job is its hosted run.

Alongside the hooks, every change keeps three floors: tests green on the iPhone 17 simulator for both schemes; no document-derived data persisted; no new dependency, not even an Apple one beyond the current set.

## Running the tests

```sh
TEST_BATCHED_SIM_UDID=<simulator udid> Scripts/test-batched.sh ResectaApp
cd Packages/RedactionEngine && swift test --no-parallel --skip FileProtectionTests
```

`TEST_BATCHED_SIM_UDID` is required — it pins the simulator by id and the runner exits 2 without it; export it before pushing. The batched runner builds once, then runs the suites in serial batches (performance-budget suites run alone, report-only, and the suites on the script's exclusion list never gate), because a full-parallel run has wedged the simulator runtime — do not substitute a full-parallel `xcodebuild test` pass. It prints one `state=… tests=… passed=… failed=… skipped=… known-issues=…` line per batch and ends with a `VERDICT:` line: `PASS` (exit 0), `FAIL` (exit 1) listing the offending suites, or `INCOMPLETE` (exit 2) when an invocation had to be killed, or its test host twice refused to launch, and its suites went unverified — re-run those. Logs and per-batch `.xcresult` bundles land under `/tmp/test-batched-<scheme>-<stamp>/`.

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
- Any uncertainty about whether existing code matches its documented contract.

If a pull request crosses one of these, mark it as draft and open an issue that states the plan so the maintainer can agree to it before the edit lands. When a change touches a documented contract, the contract description and the code change land in the same commit.

## Mechanism-description language

User-facing strings, doc comments, and commit messages describe what the code does (the mechanism), not what the user experiences (the outcome); outcome claims create express-warranty risk. The hook's language check (M-1) reads only the lines a change adds, never the commit message; it is the floor, and a human read of everything is the bar. `LegalPhrases:safe` (a trailing comment on the line; `<!-- LegalPhrases:safe -->` in Markdown) is for prose that has to use one of the listed words, and it is rare: if it appears more than a few times in one change, the language is drifting and needs a rewrite.

## Sign-off and licence

Contributions from outside the project carry a `Signed-off-by:` line on every commit (`git commit -s`), certifying the [Developer Certificate of Origin 1.1](https://developercertificate.org/); no check enforces it. The project is licensed under Apache-2.0 and uses no Contributor License Agreement.

## Security and conduct

Vulnerability disclosure goes through [`SECURITY.md`](./SECURITY.md), not the public issue tracker. Conduct: [`CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md).
