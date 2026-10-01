# Known Issues

> Tracked bugs, spec gaps, and implementation constraints.
> Severity: Critical / High / Medium / Low.
> When fixed, move to the **Fixed** section with the resolution and date.

---

## Open

### KI-1: CGPDFContext Cannot Replace Written Pages (High)
**Affects:** PDF reconstruction, verification

Once `CGPDFContext` writes a page via `endPDFPage()`, it cannot be replaced or removed.
Fill verification therefore runs on the bitmap before a page is written; a failure
re-renders the page once at the lowest resolution tier (150 DPI), and a second
failure fails the run. The post-export
verification pass never rewrites pages. A two-pass architecture that verifies the
whole file in memory before writing is deferred to a later release.

---

### KI-2: PDFPage.characterBounds(at:) Regression (High)
**Affects:** Text-layer handling
**Apple radar:** FB14843671

`PDFPage.characterBounds(at:)` regressed in iOS 18.

**Workaround:** Character positions are extracted through `PDFSelection`
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
**Affects:** Rasterization, pipeline integration

`os_proc_available_memory()` does not accurately reflect CGImage allocations due to
mmap/copy-on-write backing. It is not reliable for eviction thresholds; it is used
only for admission pre-flights with a fixed headroom.

**Workaround:** Evict on `didReceiveMemoryWarning` notification, not memory readings.
**Additional mitigation (2026-04-02):** `DocumentSearcher` enforces a `maxOCRPixelDimension` cap of 10,000 pixels. Pages exceeding this threshold in either axis at 300 DPI are skipped for OCR search rather than allocated, and the search results carry a banner naming the affected pages ("Pages 3 and 5 were too large to scan for text — image content there was not searched."). This prevents oversized bitmap crashes in the search path.
**Additional mitigation (2026-05-12):** A `maxOCRPixelCount` ceiling of 36,000,000 pixels (≈ 144 MB RGBA8) supplements the per-axis cap. The per-axis check alone admits a 10000 × 10000 thumbnail (~ 400 MB RGBA8) on near-axis-cap pages; the pixel-count cap skips OCR for those pages too, surfaced through the same too-large-to-scan banner.

---

### KI-8: Duplicate Regions from Multiple Scan Runs (Low)
**Affects:** Detection pipeline, region management

Detection applies run no overlap test, so repeated scans can add overlapping regions
for the same PII; search-result applies already skip a result an existing region
covers by more than 80 %. Security-harmless (more redaction, not less) but creates
visual clutter. Deduplication of detection applies is not scheduled.

**Workaround:** Manually delete duplicate regions before applying redaction.

---

### KI-9: Per-Page Render Timeout Reports, Not Bounds (Low–Medium)
**Affects:** Redaction pipeline (page rasterization)

Page rendering goes through a synchronous C call with no cancellation points, so the
per-page timeout cannot interrupt a draw in progress — it reports `renderTimeout` for
the affected page only once the draw completes, however long that takes. A page whose
content stream expands through deeply nested Form XObjects (many drawing operators
from a small file) can hold the render well past the timeout, and the in-app Cancel
affordance is likewise ineffective for the duration of that one page's draw. The
documented input caps (payload size, page count, page dimensions) bound input size,
not per-page drawing work.

**Workaround:** None in-app once a page's draw is underway — force-quit if a run
holds far past its progress. The run still fails with `renderTimeout` naming the
page when the draw completes; no output is produced from a failed run.

---

### KI-10: Rectangle Edges Do Not Align to Text Rows (Low)
**Affects:** Rectangle draw tool

While drawing, rectangle edges align to other boxes and page guides; alignment to recognized text rows is not available in this release (the "Snap to Text Boxes" setting that described it was removed in 1.1.0).

---

## Fixed

### KI-6: Multi-Selection State Model Missing (Low–Medium) — FIXED (entry moved 2026-08-25)
**Resolution:** `RedactionState.selectedRegionIDs` is a `Set<UUID>`; Select All / Deselect All and the "Add to Selection" toggle operate on the set (the app ships for iPhone only). The entry was stale.

---

### KI-7: Detection Orchestration Wrapper Undefined (Medium) — FIXED 2026-03-30
**Resolution:** `DetectionOrchestrator` implemented in `Packages/RedactionEngine/Sources/RedactionEngine/Detection/DetectionOrchestrator.swift` (per-page OCR and detection orchestration). The app's Scan interface runs the text detectors through the search engine and does not use it.

---

### KI-3: doc.text.redact SF Symbol Availability Unverified (Medium) — FIXED 2026-03-29
**Resolution:** Runtime availability check with fallback.
`EULAGateView.swift`, `HomeView.swift`, and the app-snapshot
privacy overlay `SnapshotPrivacyOverlay.swift` check `UIImage(systemName: "doc.text.redact")`
at runtime and fall back to `doc.viewfinder` if unavailable.

---

### KI-4: Output File Purged While Backgrounded (Medium) — FIXED 2026-05-16
**Affects:** Pipeline integration

**Resolution:** Proactive purge re-run toast wired into
`DocumentEditorView.handleScenePhaseChange(old:new:)`. The handler observes `\.scenePhase`; on a
`.background → .active` transition while the current phase is
`.verified(report)`, the handler checks
`FileManager.default.fileExists(atPath: redactionState.outputURL?.path ?? "")`
and — if the output is missing — enqueues a `.warning` `ToastQueueManager`
toast with `actionLabel: "Re-run"` that invokes
`PipelineCoordinator.runFullPipeline(documentOverride:)`. The pre-existing
`canExport` Share-button disable remains in place as defense-in-depth.

---

### Earlier review fixes

- 2026-05-12 — regex pathological-shape gate and cooperative cancellation in regex search; image-import decode moved off the main actor (image input later removed in 1.2.0); overlay long-press timer invalidated on view recycling.
- 2026-05-13 — whole-word regex range mapping fixed for non-ASCII text (a crash); the detection review's dismiss ordering fixed.
