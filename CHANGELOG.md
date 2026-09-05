# Changelog

All notable changes to Resecta are recorded in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html). Subsection ordering within a release: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.

The entries below follow the Keep-a-Changelog index format.

## [Unreleased]

### Changed

- Documentation: shorter code of conduct; README/CONTRIBUTING/SECURITY trimmed and corrected.
- Documentation: the README links the App Store listing and resecta.app.

## [1.1.0] — 2026-08-28

### Added

- **Run-facts disclosure on the verification results screen.** Lines beneath the verdict state what the run did not cover: pages too large to scan for text, runs where detection never ran, and a degraded detector.
- **Post-share acknowledgment.** A "Shared." toast after the share sheet reports completion.
- **Review orientation line.** "N pages · M with hits" beneath the sheet header after a completed run; the page bar stays reachable while the sheet is parked at its compact height.
- **Zero-result guidance.** The zero-result state reads "No items flagged" with a calibration line and pointers to the existing controls.
- **Home from the editor.** The iPhone editor's overflow menu offers Home, which closes the open document and returns to the home screen (it replaces the menu's Open Document entry; opening a file is done from the home screen).
- **Apply from the minimized bar.** The minimized Search/Scan bar now includes an Apply button that marks just the result you are viewing; the bar is slightly taller.

### Changed

- **Share confirm for reported issues.** The alert is now a sheet that lists the reported items and completes with a slide gesture; it also covers runs whose checks were partly skipped. Backing out of the share sheet re-arms the confirm; a completed share leaves it spent for that report.
- **Confidence reads as a tier** — high, medium, or low — on review rows and region details, instead of a number.
- **Apply toast** names the remaining step: nothing is redacted until you tap Redact.
- **Dialog grammar** normalized across confirms (sentence-case question titles, verb buttons; the import-while-editing confirm reads "Replace").
- **Touch targets** floored at the default type size on the page bar, review rows, sheet header and footer buttons, popups, chips, and the canvas resize handles.
- **Reduce Motion** now applies to every slide-in transition; the post-run banner tints orange only for warnings; toast and status colors use the measured text tier; the editor toolbar keeps the brand tint on Redact only; search option toggles wait for a running search.
- **Easier-to-read support text.** The home and verification screens render their explanatory text one size larger in a darker grey; the version line and the On device / No tracking / Open source strip are no longer faint.
- **Results screen layout.** The verdict title now leads the screen directly beneath the toolbar (the symbol slot above it is removed), and a passing run shows the title alone (the "All N verification checks completed" line beneath it is gone; the check count stays in the Verification Details row). The audit-scope note closes the screen well beneath the run's timing line, the top-left toolbar button is Home, and the home screen's Settings button uses the same neutral tint as the editor toolbar.
- **Result navigation.** The Previous/Next result buttons now step through matches with the review sheet parked at its compact height, where the buttons and the position counter stay available; the current match is outlined on the page, and the list scrolls to it when the sheet is expanded.
- **Result rows.** Search and scan matches now appear highlighted inside their surrounding text, with page labels carried by the section headers and the selection count and Select All in the footer.
- **Stepping through results now zooms small matches to a readable size** and returns to the full page for large ones; on single-page documents the page stays clear of the parked search strip.

### Removed

- Unreferenced code and assets across the app and engine (no behavior change; detection outputs unchanged).
- **"Snap to Text Boxes" setting.** Rectangle edges align to other boxes and page guides; the text-row assist the setting described is not available in this release.
- **The "Add to selection…" menu** in the review sheet's footer (select-where). Rows select one at a time or with Select All; Deselect All clears.
- **The "Reason:" summary line** beneath an expanded result row. Details still opens the match rationale, which carries the detector's signals, the scores, and now that summary line.
- **The confidence word on search and scan result rows.** The match confidence is read in the match rationale; each row's colored edge is unchanged.

### Fixed

- **Verification matches ligature and compatibility forms.** The verification pass now matches ligature and compatibility forms of a sensitive term — the same normalization the search path applies — so a residue the search can locate is never invisible to the verifier.
- **A transient face-detection error no longer discards a page's other detections.**
- **Truthful degraded-detection diagnostics.** On a gazetteer-manifest signature failure the diagnostics name only the signature-gated corpora; the three reference tables that load outside the signature are no longer attributed to it, and the public detector initializer now honours the same signature verdict.
- **Drawing beneath the minimized review sheet.** With the Scan or Search sheet parked at its compact height, drawing, moving and resizing regions on the page now work; the sheet's drag gesture on iOS 26 no longer cancels the touch before the page receives it.
- **The review sheet closes when Redact starts.** Tapping Redact closes the Scan or Search sheet before the run, so it no longer covers the progress card, the results screen or the preview; Keep Editing returns with Scan and Search available again.
- **Zoom floor on the document view.** Pinching out stops at the page's fit size — the whole page in view — in the editor and in the redacted preview; the page no longer shrinks into the canvas background.
- **Rectangle tool.** Drawing always starts a new box while the tool is on (existing boxes are moved or resized with the tool off); a box's starting corner stays put while its far edge aligns to guides; boxes stay within the page; the canvas redraws after every gesture (no lingering dashed box, size label, or guide lines); size and touch thresholds are measured on screen so they feel the same at any zoom; turning the tool on clears the selection and the Add-to-Selection toggle.
- **Applying search results twice in quick succession can no longer duplicate regions.** Applies are serialized: a second apply waits for the first to commit and then skips every match the first already covered.

### Internal

- Test-suite integrity: assertion-free and tautological tests replaced or removed; the Settings suites are isolated; the perf-isolation list is complete; the pre-push hook runs the batched test runner.
- GitHub Actions: a pull-request gate (XcodeGen, app + test-bundle builds, audit and claims lints on the diff, shipped-asset hash fence); on-demand and release-tag workflows for the engine host suite and the batched simulator suite; `audit-lint.sh` gains a commit-range mode.
- Toast enqueueing uses static main-actor isolation instead of a runtime thread check.
- Regenerated gazetteer, context-keyword, adversarial and packet fixtures: provenance prose only, entry counts unchanged; fixture hash pins updated. Context assets per the approved change plans: the negative-context placeholder entry is `corp.`, the bare `ein`/`mbi` suppression tokens are label phrases (166 → 171 entries), labeled license plates carry their own context words, multi-word doctype keywords are single tokens, and the FOIA and generic doctype vocabularies are rebalanced.
- The license-plate context-keyword fallback profile carries the same positive terms as the bundled context-keyword asset.
- Comments, test names and documentation rewritten to stand alone: ticket vocabulary, references to private planning documents and decision-record prose removed tree-wide; README and ENGINEERING counts regenerated by `Scripts/doc-metrics.sh`; CONTRIBUTING's branch name and sign-off posture updated.

## [1.0.0] — 2026-08-12

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
- **Document metadata stripped on export** — author, editing history, tagged structure, and other source metadata fields are removed from exported documents. The rebuilt file carries a producer tag replaced with a fixed value ("Resecta", identifying neither the operating system version nor the build), and fresh creation/modification timestamps from the system PDF writer (not metadata-free — see `PRIVACY.md`).
- **Pixel-destruction core shared by both modes.** Each affected page is rasterized; vector text and images are converted into flat bitmap data, and the redaction process is designed to remove the original text layer from marked regions.
- **Searchable Redaction text-layer design.** The reconstructed text layer uses a fresh monospace font with uniform spacing, designed to remove the glyph-positioning side channels identified in academic research on sandwich PDFs.

[Unreleased]: https://github.com/Merlin1A/resecta/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/Merlin1A/resecta/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Merlin1A/resecta/releases/tag/v1.0.0
