# RedactionEngine

Swift Package providing on-device PDF redaction primitives for the
[Resecta iOS app](../../README.md). The engine is the SPM library half of
the repository; the iOS app at `Sources/ResectaApp/` is one consumer, and
the package is import-friendly for downstream macOS or CLI builds that
need the same detection / redaction / verification pipeline without the
SwiftUI surface.

## Status

V1.x. Public surface is stable for in-tree consumers; external SPM
consumption is supported and the package follows semantic versioning
from 1.0.0, matching the `.package(url: ..., from: "1.0.0")` pin below. A
per-symbol DocC catalog is deferred to V1.1+; package-level orientation
lives in this README.

## Public surface

The package source root is `Sources/RedactionEngine/`, organized into 12
top-level subdirectories. Each owns a contract surface — the entries
below describe what each subsystem produces or consumes; types within
each subdirectory cross-reference each other through the `Models/`
shared types.

- **Audit** — Loads and translates the rule catalog from bundled JSON,
  mapping engine-generated rule IDs to catalog version-stable
  identifiers for audit-export record binding.
- **Detection** — Orchestrates the multi-stage PII detection pipeline
  (OCR, document-type classification, regex / NLTagger PII matching,
  spatial address assembly, and face detection) to produce per-page
  detection results with confidence scores.
- **Export** — Serializes search results and applied redactions into
  CSV and JSON audit artifacts with consistent schema versioning,
  redacting raw matched text on export when the user opts out of
  collection.
- **Import** — Analyzes PDF annotations using PDFKit to classify
  document profile (unredacted / partially redacted / redacted) and
  extract annotation metadata from existing markup.
- **Instrumentation** — Records cold-start timing metrics (engine-load
  duration and first-detection timing) for performance analysis;
  release-build implementation compiles to no-ops.
- **Models** — Defines public data structures for the pipeline:
  detection results, page output, document profile (PDF annotation
  classification — unrelated to the removed `RedactionProfile` type),
  keyword profiles (per-detector context-window tuning), pipeline modes,
  and verification metadata that cross subdirectory boundaries. User
  term and saved-regex persistence lives in the app target
  (`UserTermsStore` / `SavedRegexStore`), not in this package.
- **PDFInternals** — Provides low-level PDF structure traversal via
  CoreGraphics and PDFKit, reading both metadata (Layer 5 fields) and
  active content (Layer 4) for security analysis.
- **Pipeline** — Processes individual PDF pages through rasterization,
  character filtering, pixel destruction, and text-layer reconstruction,
  coordinating DPI budgeting and memory constraints across the
  rendering pipeline.
- **Resources** — Bundles pre-built detection artifacts (rule catalog,
  classifier thresholds, gazetteer data, bloom filters, context
  keywords) into the package for stateless loading at init time.
- **Search** — Performs dual-path document search (text-layer and OCR)
  with progressive results via `AsyncStream`, applying regex length /
  timeout bounds and Unicode normalization for consistent text matching.
- **Utilities** — Provides shared utilities including Unicode
  normalization (ligature expansion + NFKC) for text matching across
  search, verification, and audit subsystems.
- **Verification** — Runs multi-layer output verification on redacted
  PDFs, executing byte-oriented pattern matching, OCR confidence checks,
  and reconstruction layer checks to validate pixel destruction.

## Privacy contract

The engine ships with a bounded privacy floor. The rules below are
load-bearing for the [Resecta app's threat
model](../../README.md#threat-model) and are not configurable at
runtime.

- **No networking.** The engine performs all detection on-device. The
  package contains no networking imports (`URLSession`, `URLRequest`,
  `NWConnection`, `NWPathMonitor`, `WKWebView`); the project's
  [`audit-lint`](../../Scripts/audit-lint.sh) M-3 hook blocks any
  reintroduction at commit time.
- **Document-derived data does not persist.** Matched-text strings,
  context snippets, page indices, and normalized rectangles are
  produced per-scan and held in memory for the duration of the scan;
  the engine exposes no API that writes them to disk. The intra-session
  result-diff fingerprint is composed from geometry + category only —
  never a hash or copy of matched text.
- **Saved-search payloads carry query shape only.** The `SavedSearch`
  Codable surface stores mode, query / terms, enabled categories,
  threshold floors, and filter shape. The decoder rejects unknown keys
  at decode time to block forbidden document-derived fields from
  reaching the persisted blob.
- **Closed-vocabulary gazetteer.** Every keyword shipped in
  `Resources/Gazetteers/` belongs to a fixed, bundled vocabulary;
  non-empty load assertions raise at init if the bundle is missing or
  truncated.

User-facing prose that touches the engine surface should use
mechanism-description language (see the root
[`CONTRIBUTING.md`](../../CONTRIBUTING.md)) before landing.

## Gazetteer extension shape

Detection-time keyword lists live at
`Sources/RedactionEngine/Resources/Gazetteers/`. Adding a new keyword
set:

1. Drop a JSON file (or `.bloom` artifact, for large corpora) into the
   Gazetteers directory. The directory is `.copy`-bundled by
   [`Package.swift`](Package.swift); SPM picks it up automatically.
2. Document the file in `gazetteer-manifest.json` (canonical inventory).
3. Wire the load path through `Resources/` and assert non-empty load at
   init.
4. Add a local invariant test (run on iPhone 17 simulator before
   release) that the file's keywords are drawn from the closed
   vocabulary — this blocks accidental introduction of document-derived
   strings into the bundled corpus. There are no automated CI gates;
   manual verification gates each release.

## Concurrency

The concurrency model:

- The engine target compiles with `NonisolatedNonsendingByDefault`
  (SE-0461). Functions are nonisolated by default; methods that need
  parallel execution mark themselves `@concurrent`.
- The iOS app target compiles with `MainActor` default isolation
  (SE-0466). The boundary between the two is the standard pattern:
  `MainActor` coordinator → `await engine.<concurrent method>` →
  back to `MainActor`.

Engine APIs that do CPU-bound work (detection, verification,
rasterization) are off-`MainActor`; APIs that produce progressive
results return `AsyncStream` so the caller can subscribe from any actor.

## Importing as an SPM dependency

The engine is published as a single library product, `RedactionEngine`,
with iOS 26 as the minimum platform. To consume it externally:

```swift
// In your Package.swift:
dependencies: [
    .package(url: "https://github.com/Merlin1A/resecta", from: "1.0.0"),
],
targets: [
    .target(name: "YourTarget", dependencies: [
        .product(name: "RedactionEngine", package: "resecta"),
    ]),
]
```

For monorepo development against a local checkout, swap the `url:` for
`path:`:

```swift
.package(path: "../resecta/Packages/RedactionEngine"),
```

## Reporting issues

- **Vulnerability reports** route through the project-level
  [`SECURITY.md`](../../SECURITY.md) — `security@resecta.app` or a
  private GitHub Security Advisory.
- **Bugs and feature requests** open against the project-level issue
  tracker; see [`CONTRIBUTING.md`](../../CONTRIBUTING.md) for the
  audit-lint, spec-pair, and DCO conventions every PR is checked
  against.
