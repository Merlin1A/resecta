# Contributing to Resecta

Resecta is maintained by one person and does not expect outside contributions in the near term; issues are welcome. This file records the gates every change passes and where each gate lives, so a reader can check that they exist.

## Setup

```sh
git clone https://github.com/Merlin1A/resecta.git && cd resecta
./Scripts/install-hooks.sh   # pre-commit = Scripts/audit-lint.sh (by symlink); pre-push = the checks a change touches
./regenerate.sh              # ResectaApp.xcodeproj from project.yml via XcodeGen
```

`project.pbxproj` is generated — never edit it by hand; re-run `./regenerate.sh` after adding Swift files. Never bypass a hook with `--no-verify`. Changes land on `main` through pull requests; releases are tagged from it.

## What every change passes

1. **The pre-commit hook** (`Scripts/audit-lint.sh`) runs the mechanical checks on the staged change; it does not read the commit message. Its rules:
   - **M-1.** Mechanism-description language on added Swift, string-catalog and Markdown lines.
   - **M-3.** The banned networking symbols on added Swift source lines, and, on every run, the call-shaped networking and hand-off symbols anywhere in the shipping source against the sites pinned in the script.
   - **M-4.** No `@AppStorage` inside an `@Observable` class.
   - **M-5.** The two banned APIs, `PKCanvasView` and `PDFPage.draw`.
   - **M-6.** The LOC ceilings — 1,500 lines on `Sources/ResectaApp/Views/SearchAndRedactSheet.swift`, 700 on any newly added Swift file.

   The script's own five checks:
   - **AL-1.** A staged `project.yml` change needs a regenerated project.
   - **AL-2.** A new entry in the app target's `resources:` block is reported as a warning, because that block enumerates nothing.
   - **AL-3.** The app-bundle sample statement and the engine's fixture copy stay byte-identical.
   - **AL-5.** A test that returns before its first assertion is refused on the lines a commit adds.
   - **AL-6.** A token in the shape of a private planning identifier — a register id, a section sign with no standard or repository document named on the line, a Markdown name the repository does not track, a package key, a working name, or, in a comment, a planning-process word, a step token or the maintainer's first name — is refused on added Swift and string-catalog lines. The added lines of a text resource under a `Tests/` or `Sources/` folder (JSON, plain text, Markdown, property lists and the like) are read as data: for the same shapes but the section sign and the three comment ones, and for the planning words `orders UPDATE` and `revision N`. The pull-request gate also reads each commit of its range on its own, and each commit's message, so a line that one commit adds and a later commit removes is still refused.

   The check ids appear in the hook's messages; the rules and their override markers (`LegalPhrases:safe`, `Networking:exempt SafariView`, `SilentGuard:ok`, `Shorthand:ok`) are documented in the script's comments.

2. **The pre-push hook** (`Scripts/pre-push.sh`):
   - It first refuses a stale generated project: it compares the path references of the live `ResectaApp.xcodeproj` with a scratch XcodeGen generation of `project.yml` and prints the regenerate commands when they differ.
   - It then diffs each pushed commit against its merge base with the local `origin/main` and checks what the change touches, with no simulator: for a change under `Packages/RedactionEngine/`, to `xcschemes/RedactionEngine.xcscheme` or to a path it does not classify, a passing host run of the engine's whole test suite on the same tree and a compile of the app scheme; for a change to the app (`Sources/`, `Tests/`, `UITestFixtures/`, `Resources/`, `project.yml`, `regenerate.sh`, `xcschemes/ResectaApp.xcscheme`, `EULA.md`, `PRIVACY.md`), the compile only; nothing for documentation and repository files, where a change under `Scripts/` runs the two scripts' `--self-test` instead. The hosted `sim-suite` check runs the app's suites on the pull request.
   - The host run is accepted, never made by the hook: a `verdict.json` under `ENGINE_HOST_VERDICT_DIR` for the pushed tree names the run's log (`swift test --skip-build --no-parallel --skip FileProtectionTests` in `Packages/RedactionEngine`), the log must still match it, and the issues the log records must be exactly the rows of `Scripts/engine-host-known-reds.txt` judged `yes`. The run's commit must exist here and have that tree, its Xcode build must be the one the push runs under, and every issue its run line counts, less warnings and known issues, must be one the log records at a location; a run that records an XCTest failure is refused. A run for another tree, a red that is not listed, a listed red that is gone, or no run at all refuses the push. The list read is the pushed tree's own: a change to it in the pushed commits is printed beside the push, not refused, so it is judged where the change is read.
   - The compile (`xcodebuild build-for-testing` for a generic simulator destination) builds the working tree, so a commit that is not checked out, or with modified tracked files, is refused.
   - `PREPUSH_SCHEME_BY_DIFF=0` runs both simulator schemes through `Scripts/test-batched.sh` for any change instead; a scheme is not run again when the runner's passing verdict file for the same tree, on the same simulator, runtime build and Xcode build, is still beside its logs, and a gating red (exit 1) or an incomplete run (exit 2) blocks the push.
   - The hook prints one summary line per pushed commit; `SKIP_TESTS=1 git push` skips the gate and logs the skip to stderr.
   - An allowed push posts a `local-suites` commit status on each pushed commit ("PASS @ tree" with the checks it needed); a `SKIP_TESTS=1` push posts none.

3. **The pull-request gate** (`ci.yml`, the `pr-gate` check required on `main`):
   - builds the app, its unit- and UI-test bundles and the engine package's test bundle without running them;
   - runs the audit lint over the lines the change adds and the claims lint over the shipping docs and the view layer's string literals (both from the base branch's copies of the scripts);
   - checks the documented counts (`Scripts/doc-metrics.sh --check`, the logging counts among them) and the shipped-asset hashes with the manifest's Ed25519 signature (`Scripts/verify-shipped-asset-hashes.sh`);
   - fails if a source or test file already over 800 lines grows (`Scripts/growth-ratchet.sh`, over the source trees and both test trees: a file that size is split along a seam, not extended — a no-growth rule on large existing files, distinct from M-6's hard caps on new files);
   - fails if the engine package's `public` and `open` declaration lines exceed the cap `Scripts/engine-public-surface-check.sh` carries, printing the count and the headroom left under the cap and under each release line cap; a pull request that adds such a declaration names it in its description with a line `ENGINE-PUBLIC +n: <the declarations>`, so every use of that headroom is visible at review.

   `CHANGELOG.md` carries git's union merge driver (`.gitattributes`), so two branches that each add lines under `[Unreleased]` merge without a conflict on them. Two further steps report without failing the check: a census of tests that can pass without asserting, and a run of the change's own copies of the lint scripts.

4. **The hosted suites.**
   - `sim-suite.yml` runs the app's unit suite on a hosted iPhone 17 simulator for every pull request to `main`, as the required check `sim-suite (ResectaApp)` beside `pr-gate`; it runs both schemes through the batched runner every Monday and on `v*` tag pushes, and one chosen scheme on manual dispatch (GitHub disables the schedule after sixty days without repository activity).
   - On the weekly and tag runs the ResectaApp job also runs the editor's link-policy UI tests (`DocumentLinkUITests`) against the bundles it built, and a failed weekly or tag run is reported by an error annotation and a step summary.
   - On the hosted runner eleven suites are left out by name (`TEST_BATCHED_EXCLUDE`): the eight whose verification pass, OCR sweep, OCR re-check or direct text recognition hangs there (two app suites, six engine suites), and three engine timing pins on the ink-fit pool that judge in seconds and miss their limits on the hosted machine. They are counted on the totals line in the job summary and named in the run's log, and the pre-push hook runs them on any push that needs their scheme (`PREPUSH_SCHEME_BY_DIFF=0` makes that every push).
   - The engine package has no separate host run: the simulator suite's engine job is its hosted run.

Alongside the hooks, every change keeps three floors: tests green on the iPhone 17 simulator for both schemes; no document-derived data persisted; no new dependency, not even an Apple one beyond the current set.

## Running the tests

```sh
TEST_BATCHED_SIM_UDID=<simulator udid> Scripts/test-batched.sh ResectaApp
cd Packages/RedactionEngine && swift test --no-parallel --skip FileProtectionTests
```

`TEST_BATCHED_SIM_UDID` is required — it pins the simulator by id and the runner exits 2 without it; export it before a run. The batched runner builds once, then runs the suites in serial batches (performance-budget suites run alone and report-only, except the few the script names as alone-gating, and the suites on the script's non-gating list, `NON_GATING`, run but never gate), because a full-parallel run has wedged the simulator runtime — do not substitute a full-parallel `xcodebuild test` pass. It prints one `state=… tests=… passed=… failed=… skipped=… known-issues=…` line per batch and ends with a `VERDICT:` line: `PASS` (exit 0), `FAIL` (exit 1) listing the offending suites, or `INCOMPLETE` (exit 2) when an invocation had to be killed, or its test host twice refused to launch or twice hung before its first test, and its suites went unverified — re-run those. Before the first batch the runner waits for the simulator to finish booting. An invocation whose test host never started a test runs once more after a simulator reboot and is listed as `launch-retried`, not as incomplete; one that hangs after its tests have started is never retried. Logs and per-batch `.xcresult` bundles land under `/tmp/test-batched-<scheme>-<stamp>/`.

The engine run is serial by design (`--no-parallel`). `FileProtectionTests` needs the iOS file-protection classes, which a macOS host filesystem cannot exercise; the simulator suite covers it: the engine scheme in the weekly and tag runs, and in the pre-push hook with `PREPUSH_SCHEME_BY_DIFF=0`.

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
