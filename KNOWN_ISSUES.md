# Known Issues

> Tracked bugs, spec gaps, and implementation constraints.
> Severity: Critical / High / Medium / Low.
> When fixed, move to the **Fixed** section with the resolution and date.

---

## Open

### KI-1: CGPDFContext Cannot Replace Written Pages (High)
**Affects:** Phase 4 (PDF Reconstruction), Phase 5 (Verification)

Once `CGPDFContext` writes a page via `endPDFPage()`, it cannot be replaced or removed.
If per-page verification fails after the page is written, the only option is to FAIL the
entire pipeline and re-run. A two-pass architecture (verify in-memory before writing)
is deferred to post-v1.0.

**Workaround:** FAIL-and-re-run entire pipeline on any per-page verification failure.

---

### KI-2: PDFPage.characterBounds(at:) Regression (High)
**Affects:** Phase 7 (Text Layer Handling)
**Apple radar:** FB14843671 (API Pitfalls)

`PDFPage.characterBounds(at:)` regressed in iOS 18. Must use PDFSelection-based
workaround for character position extraction.

**Workaround:** Use PDFSelection-based character position extraction
(`TextLayerExtractor.extractCharacters`).

**iOS 26 recheck (2026-06-14):** Still present on the
iOS 26 SDK. The A/B probe `PDFKitTextLayerTests.characterBoundsDirectVsWorkaround_iOS26`
compares the direct API against the workaround on a zero-origin Courier fixture:
`characterBounds(at:)` returns non-degenerate rects but disagrees with the
PDFSelection bounds on every glyph (agree 0/10, max delta ≈ 5.05 pt). A ~5 pt
per-glyph error on a 12 pt face is a redaction-placement risk, so the workaround
is retained and KI-2 stays open. The probe is GREEN while the regression persists
and flips RED if a future SDK fixes the API — the trigger to retire the workaround
and close this issue.

---

### KI-5: os_proc_available_memory() Lags for CGImage (Low)
**Affects:** Phase 3 (Rasterization), Phase 10 (Pipeline Integration)

`os_proc_available_memory()` does not accurately reflect CGImage allocations due to
mmap/copy-on-write backing. Cannot be used for proactive eviction thresholds.

**Workaround:** Evict on `didReceiveMemoryWarning` notification, not memory readings.
**Additional mitigation (2026-04-02):** `DocumentSearcher` enforces a `maxOCRPixelDimension` cap of 10,000 pixels. Pages exceeding this threshold in either axis at 300 DPI are silently skipped for OCR search rather than allocated. This prevents oversized bitmap crashes in the search path.
**Additional mitigation (2026-05-12):** A `maxOCRPixelCount` ceiling of 36,000,000 pixels (≈ 144 MB RGBA8) supplements the per-axis cap. The per-axis check alone admits a 10000 × 10000 thumbnail (~ 400 MB RGBA8) on near-axis-cap pages; the pixel-count cap skips OCR for those pages too.

---

### KI-6: Multi-Selection State Model Missing (Low–Medium)
**Affects:** Context menus (Amendment A10.5)

`RedactionState.selectedRegionID` is a single `UUID?`. Multi-selection requires
changing to `Set<UUID>` and updating all consumers. Both "Select All" context menu
items deferred to post-v1.

**Workaround:** Select and edit regions one at a time; bulk selection is not available in V1.0.

---

### KI-8: Duplicate Regions from Multiple Scan Runs (Low)
**Affects:** Detection pipeline, region management

Running detection multiple times may produce overlapping regions for the same PII.
Security-harmless (more redaction, not less) but creates visual clutter. Deduplication
deferred to post-v1.

**Workaround:** Manually delete duplicate regions before applying redaction.

---

## Fixed

### KI-7: Detection Orchestration Wrapper Undefined (Medium) — FIXED 2026-03-30
**Resolution:** `DetectionOrchestrator` implemented in `Packages/RedactionEngine/Sources/RedactionEngine/Detection/DetectionOrchestrator.swift`. Bridges `PIIDetector.detect(in:)` with per-page orchestration including OCR, PII detection, and face detection.

---

### KI-3: doc.text.redact SF Symbol Availability Unverified (Medium) — FIXED 2026-03-29
**Resolution:** Runtime availability check with fallback implemented in Phase 8.
`EULAGateView.swift`, `EmptyStateView.swift`, and `HomeView.swift` check `UIImage(systemName: "doc.text.redact")`
at runtime and fall back to `doc.viewfinder` if unavailable.

---

### KI-4: Output File Purged While Backgrounded (Medium) — FIXED 2026-05-16
**Affects:** Phase 10 (Pipeline Integration)
**Spec ref:** `ExportFailure.filePurged` (Export — File purged row)

**Resolution:** Proactive purge re-run toast wired into
`DocumentEditorView.handleScenePhaseChange(old:new:)` (Package E,
quality-pass-2026-05). The handler observes `\.scenePhase`; on a
`.background → .active` transition while the current phase is
`.verified(report)`, the handler checks
`FileManager.default.fileExists(atPath: redactionState.outputURL?.path ?? "")`
and — if the output is missing — enqueues a `.warning` `ToastQueueManager`
toast with `actionLabel: "Re-run"` that invokes
`PipelineCoordinator.runFullPipeline(documentOverride:)`. The pre-existing
`canExport` Share-button disable and the `FailedStateView` "Re-open
Document" Tier-2 surface remain in place as defense-in-depth.

---

## Fixes applied 2026-05-12

- (High) — fixed — `Packages/RedactionEngine/Sources/RedactionEngine/Search/DocumentSearcher.swift:592,717`. `validateRegexPattern` now delegates to `RegexSafetyPrecheck.isLikelyPathological` so the ad-hoc trigger, compose sub-mode, custom-terms editor, saved-regex compile, and user-term matcher reject unbounded group-quantifiers over alternation. `searchRegex` and `previewRegex` pass `[.reportProgress]` to `enumerateMatches`, so the per-page timeout / `Task.isCancelled` check fires between match attempts on long alternation walks. New `RegexSearchHardeningTests.swift` (10 tests) covers catastrophic shapes and the cancellation path. Residual risk: catastrophic backtracking inside a single match attempt still blocks the C call — validation in `validateRegexPattern` remains the primary defense.
- (Medium) — fixed — `Sources/ResectaApp/Views/ImportService.swift:218-253`. Image-import branch now mirrors the PDF branch: `Task.detached` dispatches to a new `nonisolated static loadImageOffMainActor` that performs `UIImage(data:)` decode, dimension cap (5000×5000), `UIGraphicsPDFRenderer.pdfData` render, and `PDFDocument` wrapping; MainActor is re-entered only for `@Observable` state updates. `renderImageAsPDF` made `nonisolated static`.
- (Low) — fixed — `Sources/ResectaApp/Overlay/RedactionOverlayView.swift:1171-1178`. `removeFromSuperview` now calls the existing `cancelLongPress()` (which invalidates `longPressTimer` and clears its companion state) before `super.removeFromSuperview()`. PDFView overlay-recycling can drop the view mid-long-press, and the scheduled `Timer` otherwise retains itself on the runloop until fire.
- (Low) — fixed (comment-only) — `Packages/RedactionEngine/Sources/RedactionEngine/Verification/VerificationEngine.swift:343-346,474-475,580-582`. `Data(contentsOf: url)` with default options resolves to `.mappedIfSafe`, the memory-mapped access the verification path requires. The three in-code comments incorrectly asserted "copy not mmap" and misattributed the rule to logging-only; all three rewritten to describe the actual mapped-if-safe mechanism. No implementation change.

## Fixes applied 2026-05-13

- (High) — fixed — `Packages/RedactionEngine/Sources/RedactionEngine/Search/DocumentSearcher.swift:735-739`. Whole-word branch of `searchRegex` no longer derives `Range<String.Index>` via `String.index(_:offsetBy:)` on `NSRange.location`/`length`. `NSRegularExpression` reports `NSRange` in UTF-16 code units, while `String.Index` offsets advance by Characters (grapheme clusters); any emoji, accented letter, or CJK glyph in matched text would push the offset past `endIndex` and raise `Fatal error: String index is out of bounds`. Replaced with `Range(_:in:)`, the Foundation interop helper that round-trips UTF-16 ↔ Character correctly and returns nil for invalid ranges. Mirrors the existing safe pattern already used at line 368 (live regex preview) and line 1467 (`contextSnippet`). Sibling `index(offsetBy:)` sites at lines 1251-1252 and 1337-1338 left alone — they offset from `String.distance` (Character count), not from UTF-16, and are safe so long as `TextNormalizer.normalizeForSearch` preserves Character counts.
- (High) — fixed — `Sources/ResectaApp/Views/DetectionTriageSheet.swift:13,108-112`. Triage sheet's Dismiss button used to call `redactionState.dismissTriage()` directly, then enqueue a toast and toggle a haptic `@State` after the dismissal had already begun. Because the parent's `.sheet(isPresented:)` binding at `DocumentEditorView.swift:280` flips false when `pendingTriage` clears and its setter calls `dismissTriage()` again, the original ordering produced two `dismissTriage()` dispatches and continued mutating `ToastQueueManager` / local `@State` while the view was tearing down — the classic "modifying state during view update" failure under iOS 26's stricter `@Observable` contract. Added `@Environment(\.dismiss) private var dismiss`. New button order: enqueue toast → toggle haptic → `dismiss()`. The binding setter still owns the single call to `dismissTriage()`. `interactiveDismissDisabled(true)` is unchanged, so swipe-to-dismiss is still blocked.
