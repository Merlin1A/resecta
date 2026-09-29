# Resecta

[![ci](https://github.com/Merlin1A/resecta/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Merlin1A/resecta/actions/workflows/ci.yml)

[![Download on the App Store](https://toolbox.marketingtools.apple.com/api/v2/badges/download-on-the-app-store/black/en-us?releaseDate=1786492800)](https://apps.apple.com/us/app/resecta/id6786922787)

On-device iOS 26 PDF redaction. Free, open-source, zero data collection — all processing happens on your device.

**App Store:** [apps.apple.com/us/app/resecta/id6786922787](https://apps.apple.com/us/app/resecta/id6786922787) · **Website:** [resecta.app](https://resecta.app)

**License:** [Apache License 2.0](./LICENSE)

**Latest release:** 1.2.0 — see the [CHANGELOG](./CHANGELOG.md).

---

## What it is

Resecta is a focused PDF redaction tool that operates entirely on your device. It is designed for anyone who needs to remove sensitive regions from PDFs before sharing them. The app makes no network requests of its own, does not create accounts, and does not collect analytics or telemetry.

**For reviewers.** The design reasoning and the check behind each claim are in [`ENGINEERING.md`](./ENGINEERING.md) (start at its "Where to start reading"); what the app defends and what it does not is [`THREAT-MODEL.md`](./THREAT-MODEL.md); the test tree is described under Testing below.

## What it does

The core workflow is:

**Import → View → Mark → Apply → Verify → Export**

1. **Import** a PDF from Files, or open the bundled sample document.
2. **View** pages and navigate the document.
3. **Mark** regions for redaction by drawing rectangles, or by selecting and applying results from Scan (on-device text detection) or Search (text, pattern, and multi-term matching).
4. **Apply** redaction. Every page is rasterized, marked or not — vector text and images are converted into flat bitmap data, marked regions are overwritten in those pixels, and the rebuilt file is designed to leave the original text layer out. Source metadata (author, editing history and the rest) is stripped; the rebuilt file carries a producer tag replaced with a fixed value and timestamps rewritten to a fixed date, so the export is not metadata-free — see [`PRIVACY.md`](./PRIVACY.md).
5. **Verify.** A multi-layer verification engine scans the output for residual content using text extraction, OCR, binary string search across multiple encodings, structural analysis, and metadata checks.
6. **Export** via the system share sheet.

## Two modes

- **Secure Rasterization** — produces image-only output and is the simplest approach for high-sensitivity documents. Verification runs as a 7-layer check.
- **Searchable Redaction** — preserves non-redacted text for selectability and search, using a fresh monospace font designed to remove glyph-positioning side channels identified in academic research. Verification runs as a 12-layer check (the five additional checks cover the preserved-text layer; both modes end with a re-run of your applied searches and a detection sweep on the output). If any unmarked text on a page shows no ink — white on white, invisible, or under a box drawn into the page — that page is exported as an image only. The stated limit: text covered by a picture in the page can still enter the text layer.

Both modes share the same pixel-destruction core. Mode choice is per-document.

## Architecture

The end-to-end pipeline. The chosen export mode selects the verification pass:

```mermaid
flowchart LR
  A[Import PDF] --> B[View]
  B --> C[Mark: scan, search, or draw regions]
  C --> D[Apply: rasterize / flatten / strip metadata]
  D --> E{Export mode}
  E -->|Secure Rasterization| F[Verify - 7-layer pass]
  E -->|Searchable| G[Verify - 12-layer pass]
  F --> H[Export]
  G --> H[Export]
```

_All stages run on-device; the redaction pipeline makes no network calls. Verification is a check, not a substitute for human review of the output._

## Known limitations

The following were deliberately deferred to a later release:

- **No "Compose" search sub-mode.** The app ships two marking
  interfaces: Scan, which runs the on-device PII text detectors, and
  Search, with three modes (Text, Regex, Multi-term). A Compose mode
  for stacked filter combinations is deferred to a future release.
- **No per-region exemption tagging.** User-defined detection terms
  live in a flat `UserTermsStore` (always-flag / never-flag lists)
  and `SavedRegexStore` (saved-regex library). Per-region FOIA
  exemption labels are deferred to a future release.
- **No audit export.** The match-audit export surface is disabled in
  this release. Its v4 wire schema (`schemaVersion = 4`) ships in code for a
  future release; a v3 column-subset export path is deferred as well.
- **Single-entry Custom Terms CRUD.** Bulk operations (paste-many,
  CSV import / export, share-profile) are deferred to a future release.
- **Secure-enclave-backed persistence is deferred to a later release.** Resecta
  retains Custom Terms (`UserTermsStore` always-flag / never-flag lists),
  the saved-regex library (`SavedRegexStore`) and saved searches
  (`SavedSearchStore`) across app launches as JSON files in the app's
  Application Support directory, written with the `complete`
  file-protection class and flagged for exclusion from device backups.
  Encrypting that storage under a Secure Enclave–backed key is the
  deferred work.

See [`KNOWN_ISSUES.md`](./KNOWN_ISSUES.md) for the open-bug tracker.

## On-device operation

- No network: the codebase contains no `URLSession` or `NWConnection` usage. This is verifiable at the source level via grep.
- No accounts, no analytics, no telemetry, no server-side components.
- On-device detection combines regex patterns and checksum validators, bundled gazetteers and context scoring, `NLTagger` named-entity recognition for names, and Vision for OCR and for locating faces and barcodes on the page. The app locates face regions so they can be redacted; it computes no face landmarks or face prints and stores nothing about them.
- The sample documents are bundled in the app — not downloaded.

Users are responsible for verifying that redaction output meets their specific requirements before sharing documents.

## Threat model

Resecta is designed to address specific risks that arise when sharing redacted documents. The list below names what is in scope and what is not; the full model — assets, adversaries, trust boundaries, accepted risks and a dated security-posture table — is [`THREAT-MODEL.md`](./THREAT-MODEL.md).

**In scope:**

- **Residual text after redaction.** Both modes are designed to rasterize every page and leave the original text layer out of the rebuilt file; Searchable Redaction adds a rebuilt layer holding only unmarked text. The multi-layer verification pass scans the output for any text or character data that remains.
- **Document metadata leakage.** Author, editing history, tagged structure, and other source metadata fields are stripped from exported documents. The rebuilt file does carry a producer tag — replaced with a fixed value ("Resecta") that identifies neither the operating system version nor the build — the writer's creation/modification timestamps, rewritten to a fixed date, and a file identifier derived from the file's own bytes; it is not metadata-free. See [`PRIVACY.md`](./PRIVACY.md).
- **Font-positioning side channels (Searchable Redaction).** The preserved text layer uses a fresh monospace font with uniform spacing, designed to remove the glyph-positioning side channels identified in academic research on sandwich PDFs.

**Out of scope:**

- **Compromised device.** Resecta runs on the user's device. If the device is compromised, the threat model assumes the attacker already has access to whatever the user is redacting.
- **Malicious input documents.** Resecta does not sandbox PDF parsers. A document crafted to exploit Apple's PDF or image stack is outside the scope of what this tool addresses.
- **Network adversaries.** Resecta makes no network requests of its own — the source contains no `URLSession` or `NWConnection` calls, verifiable at the source level via `grep`.
- **Human review of output.** Users are responsible for visually reviewing redacted documents before sharing. The verification pass is a check, not a substitute for review.

## How we verify these claims

Each load-bearing claim in this README is paired with a mechanical check in this repo. The map below is the short version; the depth, the design reasoning, and the honest limits of each check are in [`ENGINEERING.md`](./ENGINEERING.md).

| Claim | Check |
| --- | --- |
| Marked regions are destroyed, not covered | Per-region pixel readback after every fill — one wrong pixel fails the render, the page is re-rendered once at half resolution, and a second failure fails the export (`Pipeline/PageRasterizer.swift`); the classic annotation-over-text attacks are constructed and destroyed in `SecurityTests/FakeRedactionTests.swift` |
| The exported file is re-checked independently | The 7/12-layer verification pass re-opens the output and scans its text, OCR of its rendered pages, the raw bytes across seven encodings (outside content streams) plus each page's decoded text, its structure and its metadata, re-runs each applied search on the output, and runs the app's structured detectors on the output to report what remains — names and addresses are not swept (`Verification/VerificationEngine.swift`) |
| Placement survives rotated pages | A rotation × crop-box-origin test matrix positions its regions with a transform written independently of the production code (`SecurityTests/RotatedPageCoordinateTests.swift`) |
| No network requests of its own | A source grep for networking symbols returns no code references (the sole hit is a comment); the pre-commit hook rejects those symbols on every added Swift source line (`Scripts/audit-lint.sh`) |
| The app's own copy doesn't overclaim | A banned-vocabulary lint walks every localized string and the shipping docs (`Tests/ResectaAppTests/LegalPhraseLintTests.swift`, `Scripts/claims-lint.sh`) |
| Bundled detection data is what the pipeline signed | An Ed25519 signature over the gazetteer manifest is verified at load; failure degrades detection with a visible banner (`Detection/GazetteerLoader.swift`) |

## Project layout

App source lives in `Sources/ResectaApp/`. The redaction engine is an SPM package at [`Packages/RedactionEngine/`](./Packages/RedactionEngine/), consumed through standard SwiftPM (the package also builds on macOS for host-side tests; no macOS product exists).

## Contributor quickstart

1. **Clone and install hooks.**

   ```sh
   git clone https://github.com/Merlin1A/resecta.git
   cd resecta
   ./Scripts/install-hooks.sh
   ```

   The pre-commit hook is a symlink to `Scripts/audit-lint.sh`, which runs the mechanical checks described in [`CONTRIBUTING.md`](./CONTRIBUTING.md); the pre-push hook runs both test schemes. Never bypass them with `--no-verify`.

2. **Generate the Xcode project.**

   ```sh
   ./regenerate.sh
   ```

   `ResectaApp.xcodeproj` is regenerated from `project.yml` via XcodeGen. Do not edit `project.pbxproj` by hand.

3. **Open in Xcode and build.**

   ```sh
   open ResectaApp.xcodeproj
   ```

   Select the **ResectaApp** scheme and an iPhone 17 simulator. Build with `⌘B`. The app target uses iOS 26 and Swift 6.2; the `RedactionEngine` SPM package requires Swift 6.2 strict concurrency.

Tests and gates: [`CONTRIBUTING.md`](./CONTRIBUTING.md).

## Testing

The test tree is larger than the source tree: roughly 68,000 lines of Swift source to roughly 102,000 lines of test code, about 1.5×. Counted from the current tree:

- **Engine package** (`Packages/RedactionEngine/Tests`) — 1,990 Swift Testing `@Test` functions across 269 suites: the pipeline and rasterization, the verification layers, the security suites (fake redaction, pixel destruction, rotated-page coordinates, adversarial verification), search, detection, and the corpus measurement harnesses.
- **App target** (`Tests/ResectaAppTests`) — 1,708 `@Test` functions across 243 suites: the pipeline state machine, cancellation and restart races, view-level predicates, and the honesty guards that keep the docs and UI copy accurate.
- **UI / end-to-end** (`Tests/ResectaAppUITests`) — 50 XCUITest methods that drive the built app on a simulator (run from Xcode; the batched runner and CI build them without running them): the first-launch legal gate, detection review, search-to-redaction flows, the search re-check on the results screen, and the editor's handling of links inside a document.

Together the suites carry about 9,300 `#expect`/`#require` assertions. Beyond ordinary coverage, they pin the things this project cannot afford to regress: the named fake-redaction attacks (text under an opaque annotation must be destroyed at the text-layer, byte, and annotation level), the rotation × geometry placement matrix, fill-readback edge cases, cancellation and restart races, and the app's own copy — overclaiming is treated as a defect class with its own red tests. The reasoning behind that structure is in [`ENGINEERING.md`](./ENGINEERING.md).

Run both suites:

```sh
TEST_BATCHED_SIM_UDID=<simulator udid> Scripts/test-batched.sh ResectaApp
cd Packages/RedactionEngine && swift test --no-parallel --skip FileProtectionTests
```

`TEST_BATCHED_SIM_UDID` is required — it pins the simulator by id and the runner exits 2 without it. `FileProtectionTests` needs the iOS file-protection classes, which a macOS host filesystem cannot exercise; the simulator suite covers it.

**On GitHub Actions.** Every pull request runs the required `pr-gate` check (`ci.yml`), which builds the app and its unit- and UI-test bundles without running them, runs the audit lint over the lines the change adds and the claims lint over the shipping docs (both from the base branch's copies of the scripts), checks the documented counts and the shipped-asset hashes, and fails if a source file already over 800 lines grows. `sim-suite.yml` also runs the app's unit suite on a hosted iPhone 17 simulator for every pull request to `main`, as a non-required check; it runs both schemes through the batched runner every Monday and on `v*` tag pushes, and one chosen scheme on manual dispatch (GitHub disables the schedule after sixty days without repository activity). `engine-suite.yml` runs the engine package with `swift test` on the macOS host on manual dispatch only and has not yet reached a verdict on the hosted runner.

## Contributing

- Read [`CONTRIBUTING.md`](./CONTRIBUTING.md) for the gates every change passes and the changes that need an agreed plan before they land.
- Security issues: please use [`SECURITY.md`](./SECURITY.md) — do not file public issues for vulnerabilities.

## License

Licensed under the Apache License, Version 2.0. See [`LICENSE`](./LICENSE) for the full text.
