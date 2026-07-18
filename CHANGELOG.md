# Changelog

All notable changes to Resecta are recorded in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html). Subsection ordering within a release: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.

The entries below follow the Keep-a-Changelog index format.

## [Unreleased]

## [1.0.0] — 2026-07-18

Initial public release.

### Added

- **Two redaction modes.** Secure Rasterization produces image-only output with a 5-layer verification pass. Searchable Redaction preserves non-redacted text via a fresh monospace font with uniform spacing — designed to remove the glyph-positioning side channels identified in academic research on sandwich PDFs — and runs a 10-layer verification pass (the five additional layers cover the preserved-text layer).
- **Two marking interfaces: Scan and Search.** Scan runs the on-device PII text detectors across the document and stages what they flag for review. Search matches exactly what you ask for, in three modes — Text, Regex, and Multi-term. Both interfaces deliver results into one review list with one selection model and one apply path, and each keeps its own saved list (saved scans; saved searches).
- **Review-first arrival.** Results arrive with nothing selected; a redaction happens only for items you explicitly select and apply.
- **On-device PII detection.** Regex patterns plus `NLTagger` named-entity recognition. Bundled gazetteers: federal-agency institution names (1,343 rows), address components, ZIP-to-state mapping, surname and given-name Bloom filters.
- **Custom Terms.** Single-entry CRUD for user-defined detection terms. Bulk operations (paste-many, CSV import / export, share-profile) are V1.1+ scope.
- **Audit export schema (surface disabled in V1.0).** The v4 match-audit wire schema ships in code, with the user-facing export surface disabled for this release; enabling it is scoped to a future release (see release notes for the column list and version-bump policy).
- **Doctype temperature and preset thresholds** calibrated against an iPhone 17 / A19 softmax dump.
- **Core workflow** — Import → View → Mark → Apply → Verify → Export — covering PDF and image input from Files, Photos, drag-and-drop, or the bundled sample document, with export via the system share sheet.

### Removed

- **The "Review Detections Before Applying" setting** (during pre-release development). Review-before-apply is the only behavior now: detected items always stage for review, and nothing is applied without an explicit selection, so the opt-out toggle was removed.
- **The per-run confidence slider** (during pre-release development). Detection Sensitivity in Settings is the one detection-level control; result lists show every above-threshold result, with confidence sorting and select-where filters in the slider's place.

### Security

- **No network requests of its own.** The codebase contains no `URLSession` or `NWConnection` usage. Verifiable at the source level via `grep`.
- **No accounts, no analytics, no telemetry, no server-side components.**
- **Document metadata stripped on export** — author, editing history, tagged structure, and other source metadata fields are removed from exported documents. The rebuilt file carries a generic producer tag and fresh creation/modification timestamps from the system PDF writer (not metadata-free — see `PRIVACY.md`).
- **Pixel-destruction core shared by both modes.** Each affected page is rasterized; vector text and images are converted into flat bitmap data, and the redaction process is designed to remove the original text layer from marked regions.
- **Searchable Redaction text-layer design.** The reconstructed text layer uses a fresh monospace font with uniform spacing, designed to remove the glyph-positioning side channels identified in academic research on sandwich PDFs.

[Unreleased]: https://github.com/Merlin1A/resecta/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Merlin1A/resecta/releases/tag/v1.0.0
