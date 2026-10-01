# RedactionEngine

Swift Package providing on-device PDF redaction primitives for the
[Resecta iOS app](../../README.md). The engine is the SPM library half of
the repository; the iOS app at `Sources/ResectaApp/` is its consumer. The
package also declares macOS 15, solely so `swift test` runs on a Mac host;
macOS is a tooling destination, not a supported product.

## Status

The public surface kept on purpose is the document-runner API in
[`ENGINEERING.md`](../../ENGINEERING.md) §9; `EnginePublicSurfaceTests`
pins that each of its symbols stays `public`. The rest of the package is
`internal` or on its way there: some declarations are still `public`
because the app names them. The package is
developed inside the Resecta app repository and is not published as a
standalone package (see "Importing as a local dependency" below). A
per-symbol DocC catalog is deferred to a later release; package-level
orientation lives in this README.

## Source layout

The package source root is `Sources/RedactionEngine/`, organized into the
twelve top-level subdirectories below. The entries describe what each
subsystem produces or consumes; the subsystems call each other directly
and pass the shared `Models/` types between them.

- **Audit** — Loads and translates the rule catalog from bundled JSON,
  mapping engine-generated rule IDs to catalog version-stable
  identifiers for audit-export record binding.
- **Detection** — Orchestrates the multi-stage PII detection pipeline
  (OCR, document-type classification, regex / NLTagger PII matching,
  spatial address assembly, and face, barcode and signature-candidate
  detection) to produce per-page detection results with confidence scores.
- **Export** — Serializes search results and applied redactions into
  CSV and JSON audit artifacts with consistent schema versioning; matched
  text is reduced to its first and last two characters unless the caller
  asks for the full text. The exporter returns bytes; the app writes them
  into the hardened per-session export directory this module provides
  (`TempExportDirectory`, `TempFileHardening`).
- **Import** — Analyzes PDF annotations using PDFKit to classify the
  document profile (unredacted, or redacted with a mark count) and
  extract annotation metadata from existing markup.
- **Instrumentation** — Records cold-start timing metrics (engine-load
  duration and first-detection timing) for performance analysis;
  release-build implementation compiles to no-ops.
- **Models** — Defines the data structures for the pipeline: detection
  results, page output, document profile (PDF annotation classification),
  pipeline modes, and verification metadata that cross subdirectory
  boundaries. The `UserTerm` and `SavedRegex` value types live here; their
  persistence lives in the app target (`UserTermsStore` /
  `SavedRegexStore`), not in this package.
- **PDFInternals** — Defines `PDFFinding`, the shared structural-finding
  type `Import`'s `AnnotationAnalyzer` reports through.
- **Pipeline** — Processes individual PDF pages through rasterization,
  character filtering, pixel destruction, and text-layer reconstruction,
  coordinating DPI budgeting and memory constraints across the
  rendering pipeline; also carries the active-content scan the app runs
  at import.
- **Resources** — Bundles pre-built detection artifacts (rule catalog,
  classifier thresholds, gazetteer data, bloom filters, context
  keywords) with the signed manifest, its detached signature and the
  public key that verifies it, for stateless loading at first use.
- **Search** — Performs dual-path document search (text-layer and OCR)
  with progressive results via `AsyncStream`, applying regex length /
  timeout bounds and Unicode normalization for consistent text matching.
- **Utilities** — Provides shared utilities including Unicode
  normalization (ligature expansion + NFKC) for text matching across
  search, verification, and detection.
- **Verification** — Runs the verification pass on redacted PDFs: seven
  checks on Secure Rasterization output, twelve on Searchable Redaction
  (`VerificationLayer`) — text extraction, OCR of the rendered output, a
  byte-level string search, structure and metadata checks, five
  text-layer checks in Searchable mode, then a re-run of the applied
  searches and a sweep of the structured detectors (names and addresses
  are not swept).

## Privacy contract

The engine ships with a bounded privacy floor. The rules below are
load-bearing for the [Resecta app's threat
model](../../THREAT-MODEL.md) and are not configurable at
runtime.

- **No networking.** The engine performs all detection on-device. The
  package contains no networking API symbols (`URLSession`, `URLRequest`,
  `NWConnection`, `NWPathMonitor`, `WKWebView`); the project's
  [`audit-lint`](../../Scripts/audit-lint.sh) M-3 rule rejects an added
  Swift line that names one of them, in the pre-commit hook and in the
  pull-request gate.
- **Document-derived data does not persist.** Matched-text strings,
  context snippets, page indices, and normalized rectangles are
  produced per scan and held in memory; no engine API writes them to
  disk. The audit exporter returns CSV / JSON bytes that can carry matched
  text and page indices, and the app surface that would write them is
  switched off in Release builds. In the app target, the intra-session
  result-diff fingerprint is composed from page, geometry and category
  only — never a hash or copy of matched text.
- **Saved-search payloads carry query shape only.** In the app target,
  the `SavedSearch` Codable surface stores a name, mode, query / terms,
  enabled categories, matching options, threshold floors, and filter
  shape. The encoder writes only those keys; the decoder rejects a row
  that carries any other key, which keeps it out of the app's saved-search
  list (the raw row stays in the file for a later version to read).
- **Closed-vocabulary keyword signals.** Every keyword the context scorer
  reports is drawn from a fixed list — the bundled gazetteer or a
  compiled-in profile — never from page text
  (`KeywordContributionTests`). A missing, truncated or altered asset
  fails the signed-manifest check at first load, and detection degrades
  with a visible banner.

User-facing prose that touches the engine surface should use
mechanism-description language (see the root
[`CONTRIBUTING.md`](../../CONTRIBUTING.md)) before landing.

## Gazetteer extension shape

The detection data tables live at
`Sources/RedactionEngine/Resources/Gazetteers/`. Adding a new table:

1. Build the table in resecta-datapipeline, which lists it with its size
   and SHA-256 in `gazetteer-manifest.json` and re-signs the manifest.
2. Install the pipeline output into `Resources/Gazetteers/` (the directory
   is `.copy`-bundled by [`Package.swift`](Package.swift)); the
   shipped-asset hash script fails on a file the manifest does not list,
   a listed file that is missing, and a size or digest mismatch.
3. Add the loader under `Detection/Gazetteer/` with a `LoaderVersionFence`
   check, and decide whether it reads under `GazetteerTrust`.
4. Add a non-empty load test; a keyword table also joins
   `KeywordContributionTests`.

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
rasterization) are off-`MainActor`. Document search returns an
`AsyncStream` so the caller can subscribe from any actor; the verification
run reports progress through an event callback in its caller's isolation.

## Importing as a local dependency

RedactionEngine is developed inside the Resecta app repository and is
not published as a standalone package: the repository has no root
`Package.swift`, and the package manifest lives at
`Packages/RedactionEngine/`. The engine is a single library product,
`RedactionEngine`, with iOS 26 as the minimum platform (macOS 15 is
declared for host-side tests only). To use it from
another Swift package, check out `Merlin1A/resecta` and add a local
dependency on the package directory:

```swift
// In your Package.swift:
dependencies: [
    .package(path: "<checkout>/Packages/RedactionEngine"),
],
targets: [
    .target(name: "YourTarget", dependencies: [
        .product(name: "RedactionEngine", package: "RedactionEngine"),
    ]),
]
```

Releases are tagged on the app repository: `v1.0.0` is a signed annotated
tag; `v1.1.0` is an unsigned lightweight tag; release tags from `v1.2.0`
on are signed. The engine carries no separate version.

## Reporting issues

- **Vulnerability reports** route through the project-level
  [`SECURITY.md`](../../SECURITY.md) — `security@resecta.app` or a
  private GitHub Security Advisory.
- **Bugs and feature requests** open against the project-level issue
  tracker; see [`CONTRIBUTING.md`](../../CONTRIBUTING.md) for the
  audit-lint rules the pull-request gate runs, the contract-with-code
  rule, and DCO sign-off.
