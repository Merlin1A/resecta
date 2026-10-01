# Engineering Notes

I'm Jesse Brookins. I built Resecta solo — the app, the redaction engine, the
data pipeline that builds its detection assets, and the test infrastructure —
and this file is for the reviewer who doesn't want to take the README's claims
on faith. Each section pairs a claim the project makes with the mechanical
check that keeps it true, and names the limits of that check in the same
breath, because a check whose boundaries you don't know is worse than no check
at all.

Paths that start with `Pipeline/`, `Verification/`, `Detection/`,
`SecurityTests/` or `SearchTests/` are inside the engine, an SPM package at
`Packages/RedactionEngine/`; the rest are relative to the repo root, apart
from the data pipeline's own files named in §8. The line counts, the isolation opt-out count and the encoding count in
this file are measured from the tree you are looking at by
`Scripts/doc-metrics.sh`, which the pull-request gate runs, not from a
dashboard. If you have time for one path through the code, skip to
[Where to start reading](#where-to-start-reading).

## 1. Redaction is destructive, and the app reads back its own output

The core design decision: Resecta does not edit the source PDF. Every page,
marked or not, is rendered to a bitmap, redaction fills are painted into those bitmaps, and
the export is a fresh PDF built from the redacted rasters. The source
document's object graph — its text runs, annotations, form fields, embedded
fonts — is parsed for rendering and text extraction, but it is never handed to
the export writer. There is no code path from source PDF objects to output PDF
objects. The writer (`Pipeline/PDFStreamReconstructor.swift`) receives an image
per page and, in Searchable mode, the surviving characters as plain values,
from which it draws a text layer rebuilt from scratch (§3).

The fill itself is written to be verifiable: copy blend mode (destination
pixels are replaced, not blended), anti-aliasing disabled, and every region
rect expanded to integer pixel boundaries before painting — partial-pixel
edges are exactly where anti-aliased blending would let original content bleed
through (`Pipeline/PixelOperations.swift`).

Then the app checks its own work, unconditionally. After the fills are
painted, and before the page can enter the output file, the raw bitmap buffer
is read back and every row of every region is compared byte-for-byte against
the expected fill pattern (`verifyFill` in `Pipeline/PixelOperations.swift`,
called from `Pipeline/PageRasterizer.swift`). This is not sampling and there
is no threshold: one wrong pixel fails that render; the page is re-rendered
once at the lowest resolution tier (150 DPI) and re-verified, and a second
failure fails the whole export with an error rather than shipping (the retry
is the app's: `rasterizeWithRetry` in
`Sources/ResectaApp/State/PipelineCoordinator.swift`). Polygon
regions — a path the editor does not offer in this release — get the same
readback, with the mask built by a scanline rasteriser written independently
of the Core Graphics fill, so the check shares no code with the thing it
checks.

**The honest limit:** pixel readback proves the fill is *complete* — every
pixel inside the region carries the fill colour. It cannot prove the region
was in the *right place*. Placement is covered separately: by the rotation ×
geometry test matrix (§4) and by the verification pass, which inspects the
finished file with no knowledge of how it was produced (§2). And no automated
check replaces looking at the output — the verification results screen, where
you share from, says so in its closing note.

## 2. Verification is a second, independent pass over the finished file

Once the output file is written, a verification engine re-opens it *as a file*
and hunts for residue (`Verification/VerificationEngine.swift`). Secure
Rasterization output gets seven layers, numbered here in the engine's order:

1. text extraction over every page;
2. OCR of the rendered output, with word-level boxes gated against the
   redacted regions;
3. a byte-level sweep of the raw file outside its stream data, plus a re-scan
   of each page's decoded text, for the sensitive terms that were redacted;
4. structural checks for active content and tampering (JavaScript, automatic
   actions, embedded files, form dictionaries, encryption, and multiple
   end-of-file markers — the signature of an incremental update appended
   after redaction);
5. metadata checks;
6. a search re-check that re-runs each search you applied through the search
   engine itself against the output (OCR of the rendered pages in this mode)
   and reports what it observed per search;
7. a detection sweep that runs the app's structured detectors on the output
   through the search engine (by OCR in this mode; names and addresses are
   not swept) and reports what remains in those categories, minus what you
   chose to leave unredacted.

Searchable Redaction adds five more over the preserved text layer (twelve in
total), numbered 6–10 ahead of the re-check and the sweep: spatial
exclusion (no character geometry inside a redacted region), character-count
cross-checks, font verification, character lineage, and an operator-level
re-extraction that walks the output's content streams with Core Graphics'
scanner and decodes each text-show operand with Core Graphics' own string
decoder, independent of PDFKit's page text — a second decoder cross-checking
the byte-level sweep.

Details a reviewer should know exist:

- The byte-level sweep (Layer 3) is a from-scratch, byte-oriented Aho–Corasick
  multi-pattern matcher (`Verification/AhoCorasick.swift`): breadth-first
  failure links, each term expanded across case variants × seven encodings
  (UTF-8, UTF-16BE/LE, UTF-32BE/LE, ASCII, Latin-1) and their
  ligature-composed forms, under a hard memory bound. If a
  pathological term set exceeds the bound, the automaton degrades to a no-op
  **and reports itself degraded** so the layer surfaces incomplete coverage —
  it does not silently pass.
- Checks that cannot run say so: pages skipped by OCR resource caps, pages
  OCR did not read for the re-check or the sweep, layers that could not
  execute, and per-page fallbacks all reach the results screen as explicit
  lines or states, never folded into a pass.
- The verdict tiers are calibrated against alarm fatigue: conditions that are
  expected under the chosen mode read as passing checks with a detail line,
  while every could-not-verify condition keeps its severity. A warning tier
  that fires on every normal document carries no information.
- Verification is advisory by design. A failed or attention-level verdict, a
  check that reports something it could not verify, skipped checks in a
  report with no other warning, or a verification that did not run does not
  hard-block export — it routes the share action through an explicit
  confirmation instead. I chose that over hard-blocking because the check has
  known epistemic limits (below), and a tool that refuses to hand you your own
  document on the strength of a heuristic is making a judgment it cannot back.

**The honest limits:** OCR-based checking is bounded by OCR itself — recall on
degraded scans is materially lower than on digital text, which is one reason
the product treats verification as a check on your review, not a substitute
for it (`THREAT-MODEL.md`, its opening paragraph and §6). The search re-check
and the detection sweep on image-only output are OCR-bounded the same way and
say so in their rows. The five text-layer checks
in Searchable mode inspect the text layer the app itself rebuilt; they are
strong against construction bugs, weaker against threat classes nobody has
named yet. That is the standing posture everywhere: mechanism claims, not
outcome promises.

## 3. The classic fake-redaction failures are pinned by name

The famous redaction failures — the Manafort filing, the Calipari report —
were not exotic: text was covered by an opaque shape and remained in the file,
selectable or extractable. Resecta's test suite constructs those documents and
asserts the pipeline destroys them
(`Packages/RedactionEngine/Tests/.../SecurityTests/FakeRedactionTests.swift`):

- A fixture PDF is built with real extractable text underneath an opaque
  annotation, and the test first asserts the attack works — the text *is*
  extractable from the fixture. A fixture that doesn't demonstrate the failure
  can't demonstrate the fix.
- The document is run through the production render, fill, readback and
  writer code (not a mock), and the output must satisfy three separate
  properties: the text layer no longer contains
  the string; the raw output bytes do not contain the string in UTF-8,
  UTF-16BE, or UTF-16LE; and zero annotations survive into the output.

The same directory carries the wider adversarial set: pixel-destruction
checks, adversarial verification suites that attack the *checker* rather than
the redaction, fill-consistency guard batteries for hostile colour/contrast
cases (built demote-never-silence: a borderline observation may be downgraded
in severity, never dropped), and sensitive-term absence suites.

For Searchable Redaction, the preserved text layer is rebuilt from scratch in
a fresh Courier instance — no source-document font survives; CoreText's Menlo
fallback covers glyphs Courier lacks — on a uniform per-line cell pitch
(`Pipeline/TextLayerReconstructor.swift`), a direct response to published
research showing that glyph-positioning metadata in "sanitised" PDFs can leak
redacted content. The verification pass then measures the rebuilt layer's
glyph advances against the expected metrics rather than trusting the
reconstruction (`Verification/SandwichVerification.swift`).

Before 1.0 I also ran repeated adversarial review passes over the
verification engine itself, hunting for paths where a real leak
could report as PASS. Every confirmed defect from those passes was fixed and
re-verified, and the defect classes they surfaced are pinned by the
adversarial suites above. The engine's job is to tell the truth about my own
output; it got the most hostile review in the codebase.

## 4. Placement correctness has its own matrix

Wrong coordinates are a leak: a fill painted in the wrong place destroys the
wrong content and leaves the right content intact — and everything downstream
of the fill would verify a wrong-but-complete rectangle. Rotated pages
(`/Rotate 90/180/270`) and non-zero crop-box origins are where PDF coordinate
handling goes wrong, so they are pinned by a dedicated matrix
(`SecurityTests/RotatedPageCoordinateTests.swift`): all four rotations × two
crop-box origins (zero and offset), each case asserting that the character
filter excludes exactly the glyphs under the displayed region (counted against
an unrotated reference extraction), that Searchable layers 6–10 do not fail
on the exported result, and that a tampered variant makes the spatial check
fail.

The matrix has one property I want a reviewer to notice: the test positions
its regions using its own transform, written separately from the production
rotation transform. If the production mapping is wrong or missing, the glyphs
it places miss the test's independently-computed region and the assertions go
red. A matrix that used the production transform to place its own test regions
would verify the code against itself.

Search-driven redaction on rotated pages carries the same discipline
(`SearchTests/RotatedSearchRegionTests.swift`): regions minted from search
results on a rotated page must export OCR-clean, and with the term absent at
both a zero and an offset crop-box origin.

## 5. The app's own copy is under test

Overclaiming is a defect class here, tested like any other:

- `LegalPhraseLintTests` walks **every localized string** in the app's legal
  string catalog and fails on any match against a banned outcome-promise
  vocabulary — the absolutes and superlatives that turn a mechanism
  description into a warranty. The list itself lives in
  `Sources/ResectaApp/Legal/LegalPhrases.swift`; I won't reproduce it here,
  since these docs are scanned by the same rules.
- `Scripts/claims-lint.sh` sweeps the shipping markdown set and the SwiftUI
  view-layer string literals for the same vocabulary, so the docs are held to
  the same bar as the UI.
- The pre-commit hook (`Scripts/audit-lint.sh`) blocks banned phrasing on the
  Swift, string-catalog and Markdown lines a commit adds, and banned
  networking symbols on the Swift source lines it adds — the same gate for me
  and for contributors (`CONTRIBUTING.md`).
- The honesty-surface tests (`Tests/ResectaAppTests/HonestySurfacesTests.swift`)
  pin the mount predicate of the disclaimer naming the checks' limits on the
  verification results screen and its single mount, and that failed,
  attention-level and skipped verdicts surface an in-context cue on the
  output preview. The honesty copy is
  load-bearing UI, so its presence is a tested invariant, not a style choice.
- `TransparencyClaimsTests` exists because I shipped an overclaim: early docs
  said user-entered Custom Terms don't persist across launches. They do (in
  protected files under Application Support, documented in `PRIVACY.md` and
  the README). I corrected the docs, then wrote a guard that reads the docs
  from the tree and goes red if `README.md` brings back the false
  non-persistence claim, or if any of README, ENGINEERING or THREAT-MODEL
  places the terms in the superseded store. That found-it, fixed-it,
  pinned-it pattern is the project's response to its own mistakes.

## 6. The no-network claim is checkable in about a minute

The claim is precise: Resecta makes no network requests of its own; documents
are processed on device. To check it yourself:

```sh
grep -rn "URLSession\|NWConnection" Sources/ Packages/RedactionEngine/Sources
```

The expected result is a single match — a code comment noting the fact. The
pre-commit hook rejects `URLSession`, `URLRequest`, `NWConnection`,
`NWPathMonitor`, and `WKWebView` on every added Swift source line (the hook
defines one override marker, for a Safari-view wrapper; no line in the tree
uses it), so the property holds going forward, not just today. The in-app legal/support links open in a
Safari view or Mail, each in its own process — the binary embeds no web engine
of its own. The privacy manifest ships at `Resources/PrivacyInfo.xcprivacy`
and declares no collected data types and no tracking, matching `PRIVACY.md`
("Data Not Collected"). And the dependency footprint makes the review
tractable: the app's only dependency is its own engine package — there is no
third-party SDK to audit.

## 7. Concurrency and reliability discipline

Both targets build under Swift 6.2 strict concurrency: the app target is
MainActor-by-default, the engine package is non-MainActor with explicitly
concurrent entry points. The working rules, checkable by grep:

- The app target contains **one** `DispatchQueue` reference (a labeled serial
  queue for writes to the in-memory thumbnail cache) and **zero** `.main.async`
  calls — main-thread work is expressed through actor isolation, not queue hops.
- Isolation opt-outs are rare and deliberate: 25 `nonisolated(unsafe)`
  declarations across ~68,000 lines of app + engine source, and the working
  convention is a written rationale at the declaration site saying why the
  access is safe.
- Long pixel operations (fills, readbacks) run in 256-row bands with a
  cooperative cancellation check between bands, so cancelling a large job
  surrenders quickly; a dedicated latency suite measures that budget. Page
  rendering goes through a synchronous C call with no cancellation points, so
  a timeout task races it and *reports* an over-long render rather than
  bounding it: the draw cannot be interrupted, the error surfaces once the
  render completes, and the app's Cancel is likewise ineffective for the
  duration of one page's draw (`KNOWN_ISSUES.md` KI-9). The one place
  cancellation cannot reach is documented rather than assumed away.
- Cancel and restart paths have their own regression suites: re-running the
  pipeline mid-flight must not interleave two runs' state
  (`PipelineCoordinatorRestartRaceTests`), cancelling during verification
  keeps the output and reports the check as skipped
  (`DocumentStateVerifyingCancelTests`), and `ImportServiceCancelTests`
  covers import cancellation (report-only in the batched runner).
- When a crash could only be reproduced in the running app (a SwiftUI
  Observation crash from cache mutation during `List` body evaluation), the
  regression test drives the real app flow (`SearchMarkForRedactionUITests`,
  a UI test run from Xcode); the hosted-view suite beside it does not
  reproduce the crash and says so in its header
  (`SearchResultsListObservationCrashTests`).
- Memory hygiene is mechanical: bitmap buffers are wiped with `memset_s`
  (which the compiler cannot elide) before returning to the context pool;
  temp export files are hardened, excluded from backups, and cleaned per
  session — each property pinned by its own test
  (`PixelBufferZeroizeTests`, `BackupExclusionTests`, `FileProtectionTests`;
  the zeroize timing budget sits in its own suite,
  `PixelBufferZeroizeTimingTests`, which the batched runner runs alone and
  report-only).

## 8. The detection data ships under contract

The gazetteers and filters the detector uses are built in a separate
open-source repo (`resecta-datapipeline`) and consumed here as bundled
assets. The contract between the two repos is enforced, not eyeballed:

- The pipeline's gate (`make verify`) runs lint, types, tests, schema
  validation, a hash-lock check of built artifacts against pinned SHA-256
  values, and a determinism rebuild whenever a builder's inputs changed since
  the last passing one (always, in the pipeline's weekly verify workflow) —
  the same inputs must produce byte-identical outputs side by side. Raw inputs
  are fetched by hand: most fetch scripts record each file's SHA-256 in
  `SOURCES.md` and refuse a later fetch whose bytes differ; the rest leave
  that row to a hand step, and the ParaNames fetch checks its download
  against the pinned row. The builders make no network calls, and a personal-e-mail
  guard (`scripts/check_no_pii.py`) runs on every pull request and first in
  the verify script, so cleanup rules are enforced by tooling rather than by
  memory.
- At first load, the app verifies an Ed25519 signature over the gazetteer
  manifest (`Detection/GazetteerLoader.swift`): detached signature, bundled
  public key, both produced by the pipeline's signing step. The signed
  manifest lists every other bundled detection asset with its SHA-256 and
  size, and each file is checked against its entry once per process
  (`Detection/Gazetteer/AssetIntegrity.swift`). **Runtime tamper detection of
  the installed app is the app-bundle code signature, which seals these same
  files.** The manifest's per-asset digests are pipeline-to-bundle provenance,
  verified at first load, so the bytes the detector reads are the bytes the
  pipeline shipped. On any verification failure, detection degrades with a
  visible banner — never silently.
- What that verdict governs, precisely: one memoized verdict
  (`Detection/Gazetteer/GazetteerTrust.swift`, computed once per process) is
  consulted by both loading paths — the diagnostics loader and the public
  detector initializer's defaults.
- On a failed signature, or a digest failure on any file the gated loaders
  read, five loaders are withheld from detection and reported by name: the
  name Bloom filters (with their sidecars), the driver's-license and passport
  pattern gazetteers, the context-keywords loader, and the negative-context
  gazetteer (the context-keyword and institution tokens still seed the OCR
  recognizer's custom-word hints outside the verdict).
- Three reference tables load outside that verdict by design and stay live —
  the institution gazetteer, the address-components gazetteer, and the
  ZIP-to-state table — as do the Classifier assets and the audit rule catalog;
  a digest failure on one of them is recorded in the load diagnostics and
  raises the banner, and the asset stays in use unless its own loader
  rejects it, when its built-in fallback applies. Every loader that decodes a
  versioned table fences its wire version, so a table from a future or stale
  schema is refused by name rather than read. The degraded-detection banner
  tells an OS-name-model-only degrade from a corpus-load failure; the withheld
  loaders are recorded in the load diagnostics.
- One asset additionally carries a load-time content check: the context-scorer
  weights file is SHA-256-hashed at load against a compiled-in constant, with
  an identity-scorer fallback on mismatch. That fallback — and the equivalent
  fallbacks for the doctype-temperature and preset-thresholds assets (identity
  temperature, built-in defaults) — reports through the same visible-degrade
  diagnostics as the corpus loaders, so a quality asset that fails to load
  surfaces in the banner rather than only in the log.
- On the test side, cross-repo fixtures and ground truth are pinned by
  SHA-256 constants that move as single, reviewed changes — drift between
  what the pipeline builds and what the app's tests expect shows up as a red
  test, not a silent skew. `Scripts/verify-shipped-asset-hashes.sh`, which the
  pull-request gate runs, pins `preset-thresholds.json`, `context-scorer.json`
  and the manifest public key byte-exact and checks the signed manifest's
  asset list against the shipped tree.

The trust boundary this section implements — what the signature proves and
what it does not — is stated for readers in [`THREAT-MODEL.md`](./THREAT-MODEL.md)
§4, and the key's custody in the pipeline's `KEY-MANAGEMENT.md`.

## 9. The engine's public surface is the document-runner API

The engine is a separate Swift module, so `public` is exactly what the app
(or any other client) can see. The surface I keep public on purpose is the
document-runner surface — what a client needs to import a page, rasterize it,
detect, search, rebuild, verify and export without the app's view code:

- Import and rasterize: `PDFPageData` · `PageRasterizer.rasterize`
- Detection: `DetectionOrchestrator.detectPage`
- Search: `DocumentSearcher` (`search` · `previewMatches` · the result,
  diagnostic and configuration setters · `boundingRect` · the regex
  validators · `maxResults` · `sharedLoadDiagnostics`) · `SearchMode` ·
  `SearchOptions` · `SearchResult` · `SearchPreviewResult` · `TextSpan`
- Rebuild: `PDFStreamReconstructor`
- Verification: `VerificationEngine.runLayer` / `aggregateStatus` /
  `layers(for:)` · `VerificationOrchestrator` · `VerificationReport` ·
  `LayerResult` · `VerificationLayer` · `AppliedSearchQuery` ·
  `AppliedSearchRecord` · `ScanRunConfiguration` · `SearchRecheckRequest`
- Export: `TempExportDirectory` · `TempFileHardening` · `ExportMetadata` ·
  `MatchAuditExporter`

`TextSpan.words(fullyInside:polygon:on:)` returns the words of a page's text
layer fully inside a region, in the displayed frame; at the start of each run
the app captures a manual region's words through it, on pages with a usable
text layer, as terms the verification pass searches for.

These are public because a runner or the app consumes them, along with the
types their signatures carry and whatever else the app names; everything else
in the package is `internal` or on its way there, and the test suites reach it
through `@testable import`, so narrowing the surface costs no coverage.

The check: `EnginePublicSurfaceTests` names every symbol in the list through a
plain `import RedactionEngine`, so making one of them `internal` stops the
engine test target from compiling. Its limit: it pins presence, not absence —
nothing in it stops a new declaration from being made `public`; that stays a
review question.

## Where to start reading

If you review one path end-to-end, make it this one:
`Pipeline/PageRasterizer.swift` (render → fill → readback) →
`Pipeline/PDFStreamReconstructor.swift` (rebuild) →
`Verification/VerificationEngine.swift` (the layered pass over the output) →
`SecurityTests/FakeRedactionTests.swift` (the named attack, pinned). The test
tree is larger than the source tree — about 68,000 lines of source to about
102,000 lines of tests; counts and structure are in the README's Testing
section — and the suites above are the reason I trust my own output enough to
ship it.

`THREAT-MODEL.md` states what the app protects, against whom, where its trust
boundaries lie, the accepted risks, and a dated posture table with a check per
line.
