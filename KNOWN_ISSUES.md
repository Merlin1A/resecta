# Known Issues

> Tracked bugs, spec gaps, and implementation constraints.
> Severity: Critical / High / Medium / Low–Medium / Low.
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

### KI-9: Per-Page Render Timeout Reports, Not Bounds (Low–Medium)
**Affects:** Redaction pipeline (page rasterization)

Page rendering goes through a synchronous C call with no cancellation points, so the
per-page timeout cannot interrupt a draw in progress — it reports `renderTimeout` for
the affected page only once the draw completes, however long that takes. A page whose
content stream expands through deeply nested Form XObjects (many drawing operators
from a small file) can hold the render well past the timeout, and the Stop Processing
button is likewise ineffective for the duration of that one page's draw. The
documented input caps (payload size, page count, page dimensions) bound input size,
not per-page drawing work.

**Workaround:** None in-app once a page's draw is underway — force-quit if a run
holds far past its progress. The run still fails with `renderTimeout` naming the
page when the draw completes; no output is produced from a failed run.

---

### KI-10: Rectangle Edges Do Not Align to Text Rows (Low)
**Affects:** Rectangle draw tool

While drawing, moving or resizing, a rectangle's edges align to the edges of the boxes beside it; alignment to recognized text rows is not available.

---

### KI-11: Barcodes and QR Codes in Images Are Not Read (Medium)
**Affects:** Image import · Scan · verification

A barcode or QR code in a photo is not read or flagged: text recognition reads printed characters, and neither Scan nor verification decodes codes. A code that carries personal data (a boarding pass, the PDF417 block on an ID card) stays readable in the redacted copy unless you draw a region over it.

---

### KI-12: Some Non-ASCII Passwords Do Not Unlock a Document (Low)
**Affects:** Import (password-protected PDFs)

A password that contains accented Latin letters, such as ä or é, does not open a PDF encrypted with 128-bit or 256-bit AES, even when it is the correct password: PDFKit refuses it, and the password sheet reports that the password did not open the document. A 256-bit AES PDF whose password is written in Chinese characters opens, but Search and the page preview on that document can stop with "Could not prepare the document for search", because PDFKit returns no copy of the unlocked document for Search to read.

**Workaround:** Open the PDF with its password in another app, save a copy without a password, and import that copy.

---

### KI-13: Some Images on Typed Pages Are Not Read by Search (Low–Medium)
**Affects:** Search (typed pages that also carry images)

On a page with a text layer, Search also reads the page's images for text when one image holds at least 250,000 pixels or covers about half the page, or when the page's text layer is very short for its size (a stamp or a Bates line over a scan). Otherwise it does not read text in a smaller image (a thumbnail-sized photo), in an image written inline in the page's drawing instructions, or in text drawn as outlines rather than as characters. When you have applied at least one result of a typed search, the check after export reads every page of the redacted copy for that term and can report it if it is left in such an image. A search that found nothing is not run again after export, so a term that appears only in such an image is not reported. Names found by Scan are not checked that way.

**Workaround:** Draw a region over the image.

---

### KI-14: The No-Match Message Does Not Qualify Another App's OCR Text (Medium)
**Affects:** Search (scanned PDFs whose text layer was made by another app's OCR)

When Search reads pages by text recognition and a search returns no match, the message says how many pages were read that way, because a misread word does not match. A scanned PDF whose invisible text layer was made by another app's OCR is read as a page with text, so a search with no match on it shows the plain "No occurrences in the document" message, although that layer can hold the same misreads. Search's no-match message doesn't yet qualify pages whose text layer came from another app's OCR; check scanned pages by eye.

**Workaround:** Check scanned pages by eye, or search a shorter part of the term.

---

### KI-15: A Word Split by a Hyphen Across Two Lines Is Not Matched Whole (Low)
**Affects:** Search

A word that a hyphen splits across two lines is matched as two separate words, so a search for the whole word does not match it.

**Workaround:** Search for each part, or draw a region over the word.

---

### KI-16: A Photo Kept Only in iCloud Does Not Import Offline (Low)
**Affects:** Import (Photos)

A photo whose full-size copy is kept only in iCloud, as with Optimize iPhone Storage, has to be downloaded by iOS before Resecta can read it. Without a network, iOS cannot download it, and the import stops with "The file could not be read. It may be damaged, locked by another app, or temporarily unavailable." One such photo stops the whole pick.

**Workaround:** Connect to a network and pick the photos again, or open each photo in the Photos app first so iOS downloads it.

---

### KI-17: On a Photo or Scanned Page, a Search Box Covers the Whole Line (Low–Medium)
**Affects:** Search (text read from a picture: a photo, a screenshot, a scan, or a photo on a typed page); hand-drawn regions on pages with no text layer

On a page that is a picture, such as a photo, a screenshot or a scan without its own text, Search reads the text with on-device text recognition, which reports where each line is rather than each word. A box placed from a Search match on such a page covers the whole line that holds the match, so the other words on that line are covered too.

A region you draw by hand on a page with no text layer (a photo, a screenshot or a scan without its own text) is not read by any check: no words are captured under it, so the checks cannot tell what it covers. The Binary String Search check notes how many hand-drawn regions added no term (a region that covers its whole page, or one on a page with no text layer) but does not say which pages hold them.

**Workaround:** Before you tap Redact, select the box and drag its handles in to the word, leaving a margin around its letters: a box drawn to the edges of the letters can leave part of them readable. Check the page in the preview before you share. For a region you drew by hand on a page with no text layer, check in the preview that the region covers what you meant.

---

### KI-18: A Bar or Cover Already in a Received Page Can Leave Text in a Searchable Export (Medium)
**Affects:** Searchable Redaction (documents that were blacked out before you opened them)

Searchable Redaction exports a page as an image only when it reads unmarked text there as showing no ink. Bars and covers of these kinds already in a received page can defeat that reading: a dark bar that is part of a scanned picture, whose scanning noise reads as ink, over a word the page's own OCR text layer still holds; a bar drawn over live text that is not fully opaque, so the text shows through faintly; and a cover drawn over live text that is filled with a pattern, such as hatching or dots, or is a picture. The page then keeps its text layer, the word under the bar or cover can be selected, copied and searched in the export, and verification reports it only if a detector in its final sweep flags it. The sweep reads the structured categories, and a detector can weigh the words around a number before it flags it; a name or an address is not swept.

**Workaround:** For a document that was already blacked out, export with Secure Rasterization, which keeps no text layer.

---

### KI-19: A Filled PDF Form Exports with Its Field Values Removed (Low–Medium)
**Affects:** Export (PDF forms whose fields were filled in before you opened them)

A value typed into a PDF form is kept with its field, not drawn into the page itself. Resecta rebuilds the redacted copy from the page's own content in both export modes, so the copy carries no field values: a filled form exports with its fields blank. Resecta does not yet draw field values into the page it exports. The notice shown at import says how many filled fields are not carried into the copy.

**Workaround:** Flatten the form in another app before you import it, so its values become part of the page, then mark any values you need to redact and check the preview before you share.

---

### KI-20: On iOS 27, Text Read from Images Can Differ (Medium)
**Affects:** Search in text read from a picture (a scan, photo or screenshot) on iOS 27

On iOS 27, text read from images (scans and photos) can differ from iOS 26: a word may be read wrongly, or two words read as one, so Search may miss a term on such a page; check the page in the preview before sharing. On a scan or photo that carries its own hidden text, a Search box over a small word next to a border line can be drawn taller than the word on iOS 27, and Resecta then says the box was widened.

**Workaround:** Check each such page in the preview before sharing, and draw a box over anything Search missed.

---

### KI-21: A Multi-Word Search Can Miss Text Split Within One Scanned Line (Medium)
**Affects:** Search in text read from a picture (a scan, photo or screenshot), on iOS 26 and iOS 27

On a scanned page, a name that iOS reads as two separate pieces of one line may not be found by a multi-word search; search each word of it on its own as a fallback.

**Workaround:** Search each word of the name on its own, check each such page in the preview before sharing, and draw a box over anything Search missed.

---

### KI-22: On iOS 27, Name Detection Can Miss Names (Medium)
**Affects:** Names in Search and Scan on iOS 27

On iOS 27, the system's name model can be unavailable or unreliable. After the iPhone has been on for a long time Resecta may detect no names and says so; in some sessions it can miss names without a notice. Restarting the iPhone may bring name detection back.

**Workaround:** Check each page in the preview before sharing, search for each name you need removed, and draw a box over anything Scan missed.

---

### KI-24: On a Scanned Page, a Box Can Leave the Word in a Searchable Export (High)
**Affects:** Searchable Redaction (scanned pages that carry their own text, such as a scan made searchable by OCR)

Some scanned PDFs carry an invisible layer of text over the picture of each page, which is what makes them searchable. That layer does not always line up with the printed words: a word's hidden copy can sit a little to one side of where it is printed. A box placed from a Search or Scan match of that text, and left where it was placed, removes the hidden copy where it is. Any other box removes only the hidden text under the box itself: one you draw by hand, one made with Duplicate Region, one you resize or move after placing it, or one placed where Resecta read the word from the page's picture because the hidden text spells it differently. On such a page the hidden copy of the word you covered can stay in a Searchable export, where it can be selected, copied and searched. Verification reports it only if a detector in its final sweep flags it. The sweep reads the structured categories, and a detector can weigh the words around a number before it flags it; a name or an address is not swept.

**Workaround:** Export scanned documents with Secure Rasterization, which keeps no text layer.

---

### KI-26: Some Searchable Exports Keep the Real Export Time and iOS Version (Low)
**Affects:** Searchable Redaction

On Searchable exports that need a large fallback font, such as Chinese or Japanese text, the file keeps the real export time and iOS version instead of the fixed values. No document content is affected. Checks report this as a metadata warning.

---

### KI-27: A Searchable Export Can Write Some Letters Twice in Its Hidden Text (Low–Medium)
**Affects:** Searchable Redaction

A Searchable export carries a hidden copy of the page's text, which is what makes the file searchable. Where the original file draws two letters as one joined shape, as some typeset documents do for "fi", "fl" and "ff", the hidden copy can carry both letters twice: "Benefit" is written "Benefifit". The same can happen to a Thai syllable written with the vowel sign ำ and to an emoji made of several joined emoji. In the exported file a search for such a word can find nothing even though the word is printed on the page, and text copied from the file carries the doubles. The Character Count check can then warn on a file that is otherwise correct. Some Devanagari and Tamil marks can be missing from the hidden copy. The picture of the page is not affected. In the cases tested, a box that touched any part of such a joined shape removed all of its letters from the hidden copy. <!-- LegalPhrases:safe -->

---

### KI-28: On a Scanned Page That Reads Sideways or Upside Down, a Multi-Word Search Can Miss Text That Runs onto the Next Line (Medium)
**Affects:** Search in text read from a picture (a scan, photo or screenshot)

On a scanned page whose print reads sideways or upside down as the page is shown, a name, address or other phrase that ends one line and continues on the next is not found by a search for the whole phrase. No box is placed on it, so it stays readable in the export. Verification does not report it: its Search Re-check looks for the phrase the same way, and a search that found nothing is not run again after export.

**Workaround:** Search each word of the phrase on its own, check each such page in the preview before sharing, and draw a box over anything Search missed.

---

### KI-29: In a Searchable Export, a Number Next to a Box Can Lose Digits in the Hidden Text (Low–Medium)
**Affects:** Searchable Redaction

The hidden copy of the page's text leaves out the characters closest to a box, on purpose: any character within three points (about a millimeter) of it. A number that stands beside a box, or on the line just above or below one, can lose the digits nearest the box that way, so "1290" can read "12" when it is copied or searched, while the page you see still shows the number, whole or in part. No boxed text comes back, and no digit is added. In some files the hidden copy also loses the space between two words.

---

## Fixed

### KI-8: Duplicate Regions from Multiple Scan Runs (Low) — FIXED (entry moved 2026-10-01)
**Resolution:** Scan results are applied through the same path as search results, which skips a result that an existing region already covers by more than four fifths of its area, so applying the same scan twice adds no second region. The entry was stale.

---

### KI-6: Multi-Selection State Model Missing (Low–Medium) — FIXED (entry moved 2026-08-25)
**Resolution:** `RedactionState.selectedRegionIDs` is a `Set<UUID>`; Select All / Deselect All and the "Add to Selection" toggle operate on the set (the app ships for iPhone only). The entry was stale.

---

### KI-7: Detection Orchestration Wrapper Undefined (Medium) — FIXED 2026-03-30
**Resolution:** `DetectionOrchestrator` implemented in `Packages/RedactionEngine/Sources/RedactionEngine/Detection/DetectionOrchestrator.swift` (per-page OCR and detection orchestration). The app's Scan interface runs the text detectors through the search engine and does not use it.

---

### KI-3: doc.text.redact SF Symbol Availability Unverified (Medium) — FIXED 2026-03-29
**Resolution:** The home screen, the first-launch agreement and the app-switcher placeholder draw the app's mark from shapes; no SF Symbol is looked up for it. (The runtime check for `doc.text.redact` with a `doc.viewfinder` fallback that stood here from 2026-03-29 is removed with it.)

---

### KI-4: Output File Purged While Backgrounded (Medium) — FIXED 2026-05-16
**Affects:** Pipeline integration

**Resolution:** Proactive purge re-run toast wired into
`DocumentEditorScenePhaseHandler` (`DocumentEditorView+ScenePhase.swift`). The handler observes `\.scenePhase`; on a
`.background → .active` transition while the current phase is
`.verified(report)`, the handler checks
`FileManager.default.fileExists(atPath: redactionState.outputURL?.path ?? "")`
and — if the output is missing — enqueues a `.warning` `ToastQueueManager`
toast with `actionLabel: "Re-run"` that invokes
`PipelineCoordinator.runFullPipeline(documentOverride:)`. The pre-existing
`canExport` Share-button disable remains in place as defense-in-depth.

---

### Earlier review fixes

- 2026-05-12 — regex pathological-shape gate and cooperative cancellation in regex search; image-import decode moved off the main actor (image input was removed in 1.2.0 and returned in 1.3.0 through a new loader); overlay long-press timer invalidated on view recycling.
- 2026-05-13 — whole-word regex range mapping fixed for non-ASCII text (a crash); the detection review's dismiss ordering fixed.
