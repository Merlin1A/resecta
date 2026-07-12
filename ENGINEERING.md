# Engineering Notes

I'm Jesse Brookins. I built Resecta solo — the app, the redaction engine, the
data pipeline that builds its detection assets, and the test infrastructure —
and this file is for the reviewer who doesn't want to take the README's claims
on faith. Each section pairs a claim the project makes with the mechanical
check that keeps it true, and names the limits of that check in the same
breath, because a check whose boundaries you don't know is worse than no check
at all.

Paths are relative to the repo root. The engine is an SPM package at
`Packages/RedactionEngine/`; every number in this file is derived from the
tree you are looking at (grep counts over source), not from a dashboard.

## 1. Redaction is destructive, and the app reads back its own output

The core design decision: Resecta does not edit the source PDF. Affected pages
are rendered to bitmaps, redaction fills are painted into those bitmaps, and
the export is a fresh PDF built from the redacted rasters. The source
document's object graph — its text runs, annotations, form fields, embedded
fonts — is parsed for rendering and text extraction, but it is never handed to
the export writer. There is no code path from source PDF objects to output PDF
objects (`Pipeline/PDFStreamReconstructor.swift`: the writer receives an image
per page, plus — in Searchable mode — a text layer rebuilt from scratch; see
§3).

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
is no threshold: one wrong pixel fails the page, and a failed page fails the
whole export with an error rather than shipping. Freeform (polygon) regions
get the same treatment with one extra property: the readback mask is built by
a scanline rasteriser written independently of the Core Graphics fill path
that painted the region, so the check does not share code — or bugs — with the
thing it is checking.

**The honest limit:** pixel readback proves the fill is *complete* — every
pixel inside the region carries the fill colour. It cannot prove the region
was in the *right place*. Placement is covered separately: by the rotation ×
geometry test matrix (§4) and by the verification pass, which inspects the
finished file with no knowledge of how it was produced (§2). And no automated
check replaces looking at the output — the app's own UI says so at the moment
you share.

## 2. Verification is a second, independent pass over the finished file

After export, a verification engine re-opens the output *as a file* and hunts
for residue (`Verification/VerificationEngine.swift`). Secure Rasterization
output gets five layers: text extraction over every page; OCR of the rendered
output with word-level boxes gated against the redacted regions; a byte-level
sweep of the raw file for the sensitive terms that were redacted; structural
checks for active content and tampering (JavaScript, automatic actions,
embedded files, form dictionaries, encryption, and multiple end-of-file
markers — the signature of an incremental update appended after redaction);
and metadata checks. Searchable Redaction adds five more over the preserved
text layer: spatial exclusion (no character geometry inside a redacted
region), character count cross-checks, font verification, character lineage,
and an operator-level re-extraction that decodes the output's content streams
directly — a second decoder cross-checking the byte-level sweep, sharing no
code with the toolkit extraction.

Details a reviewer should know exist:

- The byte-level sweep (Layer 3) is a from-scratch, byte-oriented Aho–Corasick
  multi-pattern matcher (`Verification/AhoCorasick.swift`): breadth-first
  failure links, each term expanded across case variants × five encodings
  (UTF-8, UTF-16BE, UTF-16LE, ASCII, Latin-1), and a hard memory bound. If a
  pathological term set exceeds the bound, the automaton degrades to a no-op
  **and reports itself degraded** so the layer surfaces incomplete coverage —
  it does not silently pass.
- Checks that cannot run say so. Pages skipped by OCR resource caps, layers
  that could not execute, and per-page fallbacks are threaded through to the
  results UI as explicit "could not verify" states rather than folded into a
  pass.
- The verdict tiers are calibrated against alarm fatigue: conditions that are
  expected under the chosen mode are informational notes, while every
  could-not-verify condition keeps its severity. A warning tier that fires on
  every normal document carries no information.
- Verification is advisory by design. A failed or skipped verdict does not
  hard-block export — it routes the share action through an explicit
  confirmation instead. I chose that over hard-blocking because the check has
  known epistemic limits (below), and a tool that refuses to hand you your own
  document on the strength of a heuristic is making a judgment it cannot back.

**The honest limits:** OCR-based checking is bounded by OCR itself — recall on
degraded scans is materially lower than on digital text, which is one reason
the product treats verification as a check on your review, not a substitute
for it (`README.md`, threat model). The five Searchable-mode layers inspect
the text layer the app itself rebuilt; they are strong against construction
bugs, weaker against threat classes nobody has named yet. That is the standing
posture everywhere: mechanism claims, not outcome promises.

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
- The document is run through the real pipeline (not a mock), and the output
  must satisfy three separate properties: the text layer no longer contains
  the string; the raw output bytes do not contain the string in UTF-8,
  UTF-16BE, or UTF-16LE; and zero annotations survive into the output.

The same directory carries the wider adversarial set: pixel-destruction
checks, adversarial verification suites that attack the *checker* rather than
the redaction, fill-consistency guard batteries for hostile colour/contrast
cases (built demote-never-silence: a borderline observation may be downgraded
in severity, never dropped), and sensitive-term absence suites.

For Searchable Redaction, the preserved text layer is rebuilt from scratch in
a single monospace font with uniform advance widths
(`Pipeline/TextLayerReconstructor.swift`) — a direct response to published
research showing that glyph-positioning metadata in "sanitised" PDFs can leak
redacted content. The verification pass then measures the rebuilt layer's
glyph advances against the expected metrics rather than trusting the
reconstruction (`Verification/SandwichVerification.swift`).

Before 1.0 I also ran repeated adversarial review passes over the
verification engine itself, specifically hunting for paths where a real leak
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
(`SecurityTests/RotatedPageCoordinateTests.swift`): every rotation × multiple
crop-box origins, each case asserting at two levels — the character filter
must exclude exactly the glyphs under the displayed region (counted against an
unrotated reference extraction), and the full pipeline's Searchable layers
must come back clean on the result.

The matrix has one property I want a reviewer to notice: the test positions
its regions using its own transform, written separately from the production
rotation transform. If the production mapping is wrong or missing, the test's
independently-computed region lands somewhere else and the assertions go red.
A matrix that used the production transform to place its own test regions
would verify the code against itself.

Search-driven redaction on rotated pages carries the same discipline
(`SearchTests/RotatedSearchRegionTests.swift`): regions minted from search
results on rotated, origin-shifted pages must export with the term absent and
OCR-clean.

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
- The pre-commit hook (`Scripts/audit-lint.sh`) blocks banned phrasing and
  banned networking symbols in every staged diff — the same gate for me and
  for contributors (`CONTRIBUTING.md`).
- `HonestySurfacesTests` pins that the disclaimer naming the checks' limits is
  mounted on the verification results screen for **every** verdict state, and
  that failed/skipped verdicts surface an in-context cue on the output
  preview. The honesty copy is load-bearing UI, so its presence is a tested
  invariant, not a style choice.
- `TransparencyClaimsTests` exists because I shipped an overclaim: early docs
  said user-entered Custom Terms don't persist across launches. They do (in
  `UserDefaults`, documented in `PRIVACY.md` and the README). I corrected the
  docs, then wrote a guard that reads the docs from the tree and goes red if
  the false claim ever comes back. That found-it, fixed-it, pinned-it pattern
  is the project's response to its own mistakes.

## 6. The no-network claim is checkable in about a minute

The claim is precise: Resecta makes no network requests of its own; documents
are processed on device. To check it yourself:

```sh
grep -rn "URLSession\|NWConnection" Sources/ Packages/RedactionEngine/Sources
```

The expected result is a single match — a code comment noting the fact. The
pre-commit hook rejects `URLSession`, `URLRequest`, `NWConnection`,
`NWPathMonitor`, and `WKWebView` in any staged source diff, so the property
holds going forward, not just today. The in-app legal/support links open in
Safari or Mail, each in its own process — the binary embeds no web engine of
its own. The privacy manifest ships at `Resources/PrivacyInfo.xcprivacy` with
an empty collection declaration, matching `PRIVACY.md` ("Data Not
Collected"). And the dependency footprint makes the review tractable: the
app's only dependency is its own engine package — there is no third-party SDK
to audit.

## 7. Concurrency and reliability discipline

Both targets build under Swift 6.2 strict concurrency: the app target is
MainActor-by-default, the engine package is non-MainActor with explicitly
concurrent entry points. The working rules, checkable by grep:

- The app target contains **one** `DispatchQueue` reference (a labeled serial
  queue for thumbnail-cache disk writes) and **zero** `.main.async` calls —
  main-thread work is expressed through actor isolation, not queue hops.
- Isolation opt-outs are rare and deliberate: 23 `nonisolated(unsafe)`
  declarations across ~54,000 lines of app + engine source, and the working
  convention is a written rationale at the declaration site saying why the
  access is safe.
- Long pixel operations (fills, readbacks) run in 256-row bands with a
  cooperative cancellation check between bands, so cancelling a large job
  surrenders quickly; a dedicated latency suite measures that budget. Page
  rendering goes through a synchronous C call with no cancellation points, so
  it races a timeout instead — the one place cancellation cannot reach is
  documented and bounded rather than assumed away.
- Cancel/restart races have their own regression suites
  (`PipelineCoordinatorRestartRaceTests`, `DocumentStateVerifyingCancelTests`,
  `ImportServiceCancelTests`): re-running the pipeline mid-flight must not
  interleave two runs' state.
- When a crash could only be reproduced under production view hosting (a
  SwiftUI Observation crash from cache mutation during `List` body
  evaluation), the regression test hosts real views rather than settling for
  a unit harness that provably could not reproduce it
  (`SearchResultsListObservationCrashTests`).
- Memory hygiene is mechanical: bitmap buffers are wiped with `memset_s`
  (which the compiler cannot elide) before returning to the context pool;
  temp export files are hardened, excluded from backups, and cleaned per
  session — each property pinned by its own test
  (`PixelBufferZeroizeTests`, `BackupExclusionTests`, `FileProtectionTests`).

## 8. The detection data ships under contract

The gazetteers and filters the detector uses are built in a separate
open-source repo (`resecta-datapipeline`) and consumed here as bundled
assets. The contract between the two repos is enforced, not eyeballed:

- The pipeline's gate (`make verify`) runs lint, types, tests, schema
  validation, a hash-lock check of built artifacts against pinned SHA-256
  values, and a full determinism rebuild — the same inputs must produce
  byte-identical outputs side by side. Raw source downloads are validated by
  SHA-256 against a checked-in manifest, build targets make no network calls,
  and a PII-pattern guard is wired into the repo's verify script so cleanup
  rules are enforced by tooling rather than by memory.
- At load, the app verifies an Ed25519 signature over the gazetteer manifest
  (`Detection/GazetteerLoader.swift`): detached signature, bundled public
  key, both produced by the pipeline's signing step. Stated plainly: **the
  signature covers the manifest file itself** — it proves the manifest is the
  one the pipeline signed, and it does not hash every asset's bytes at load.
  Extending the manifest to carry per-asset content hashes is on the post-1.0
  list. On any verification failure, detection degrades with a visible banner
  — never silently.
- One asset already carries a load-time content check: the context-scorer
  weights file is SHA-256-hashed at load against a compiled-in constant, with
  an identity-scorer fallback on mismatch.
- On the test side, cross-repo fixtures and ground truth are pinned by
  SHA-256 constants that move as single, reviewed changes — drift between
  what the pipeline builds and what the app's tests expect shows up as a red
  test, not a silent skew. A pre-archive script
  (`Scripts/verify-shipped-asset-hashes.sh`) additionally pins the two most
  drift-prone config blobs byte-exact before any release build.

## Where to start reading

If you review one path end-to-end, make it this one:
`Pipeline/PageRasterizer.swift` (render → fill → readback) →
`Pipeline/PDFStreamReconstructor.swift` (rebuild) →
`Verification/VerificationEngine.swift` (the layered pass over the output) →
`SecurityTests/FakeRedactionTests.swift` (the named attack, pinned). The test
tree is larger than the source tree — about 54,000 lines of source to about
73,000 lines of tests; counts and structure are in the README's Testing
section — and the suites above are the reason I trust my own output enough to
ship it.
