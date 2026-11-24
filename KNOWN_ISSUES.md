# Known Issues

> Tracked bugs, spec gaps, and implementation constraints.
> Severity: Critical / High / Medium / Low–Medium / Low.
> When fixed, move to the **Fixed** section with the resolution and date.
>
> Open entries describe the current App Store release (1.3.1). An entry whose fix is on `main` but not yet released stays open until the release that carries the fix.

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

A password that contains accented Latin letters, such as ä or é, does not open a PDF encrypted with 128-bit or 256-bit AES, even when it is the correct password: PDFKit refuses it, and the password sheet reports that the password did not open the document. A 256-bit AES PDF whose password is written in Chinese characters opens, but Search on that document can stop with "Could not prepare the document for search", and the preview of matches as you type shows nothing, because PDFKit returns no copy of the unlocked document for Search to read.

**Workaround:** Open the PDF with its password in another app, save a copy without a password, and import that copy.

---

### KI-13: Some Images on Typed Pages Are Not Read by Search (Low–Medium)
**Affects:** Search (typed pages that also carry images)

On a page with a text layer, Search also reads the page's images for text when one image holds at least 250,000 pixels, or at least half as many pixels as the page itself has at 100 dpi, or when the page's text layer is very short for its size (a stamp or a Bates line over a scan). Otherwise it does not read text in a smaller image (a thumbnail-sized photo), in an image written inline in the page's drawing instructions, or in text drawn as outlines rather than as characters. When you have applied at least one result of a typed search, the check after export reads every page of the redacted copy for that term and can report it if it is left in such an image. A search that found nothing is not run again after export, so a term that appears only in such an image is not reported. Names found by Scan are not checked that way.

**Workaround:** Draw a region over the image.

---

### KI-14: The No-Match Message Does Not Qualify Another App's OCR Text (Medium)
**Affects:** Search (scanned PDFs whose text layer was made by another app's OCR)

When Search reads pages by text recognition and a search returns no match, the message says how many pages were read that way, because a misread word does not match. A scanned PDF whose invisible text layer was made by another app's OCR is counted as a page with text, so a search with no match on it shows the plain "No occurrences in the document" message, although that layer can hold the same misreads.

**Workaround:** Check scanned pages by eye, or search a shorter part of the term.

---

### KI-15: A Word Split by a Hyphen Across Two Lines Is Not Matched Whole (Low)
**Affects:** Search

A word that a hyphen splits across two lines is matched as two separate words, so a search for the whole word does not match it. The same holds for a name or a number that breaks after its own hyphen, such as a double surname or a case number.

**Workaround:** Search for each part, or draw a region over the word.

---

### KI-16: A Photo Kept Only in iCloud Does Not Import Offline (Low)
**Affects:** Import (Photos)

A photo whose full-size copy is kept only in iCloud, as with Optimize iPhone Storage, has to be downloaded by iOS before Resecta can read it. Without a network, iOS cannot download it, and the import stops with "The file could not be read. It may be damaged, locked by another app, or temporarily unavailable." One such photo stops the whole pick.

**Workaround:** Connect to a network and pick the photos again, or open each photo in the Photos app first so iOS downloads it.

---

### KI-17: On a Photo or Scanned Page, a Search Box Covers the Whole Line (Low–Medium)
**Affects:** Search (text read from a picture: a photo, a screenshot, a scan, or a photo on a typed page); hand-drawn regions on pages with no text layer

On a page that is a picture, such as a photo, a screenshot or a scan without its own text, Search reads the text with on-device text recognition. A box placed from a Search match on such a page covers the whole line that holds the match, so the other words on that line are covered too.

A region you draw by hand on a page with no text layer (a photo, a screenshot or a scan without its own text) is not read by any check: no words are captured under it, so the checks cannot tell what it covers. The Terms in Text & Bytes check notes how many hand-drawn regions added no term (a region that covers its whole page, or one on a page with no text layer) but does not say which pages hold them.

**Workaround:** Before you tap Redact, select the box and drag its handles in to the word, leaving a margin around its letters: a box drawn to the edges of the letters can leave part of them readable. Check the page in the preview before you share. For a region you drew by hand on a page with no text layer, check in the preview that the region covers what you meant.

---

### KI-18: A Bar or Cover Already in a Received Page Can Leave Text in a Searchable Export (Medium)
**Affects:** Searchable Redaction (documents that were blacked out before you opened them)

Searchable Redaction exports a page as an image only when it reads unmarked text there as showing no ink. Bars and covers of these kinds already in a received page can defeat that reading:

- a dark bar that is part of a scanned picture, whose scanning noise reads as ink, over a word the page's own OCR text layer still holds;
- a bar drawn over live text that is not fully opaque, so the text shows through faintly;
- a cover drawn over live text that is filled with a pattern, such as hatching or dots, or is a picture.

The page then keeps its text layer, the word under the bar or cover can be selected, copied and searched in the export, and verification reports it only if a detector in its final sweep flags it. The sweep reads the structured categories, and a detector can weigh the words around a number before it flags it; a name or an address is not swept. A cover that is an annotation, such as a highlight or a form field, is a different case: see KI-37.

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

Some scanned PDFs carry an invisible layer of text over the picture of each page, which is what makes them searchable. That layer does not always line up with the printed words: a word's hidden copy can sit a little to one side of where it is printed. A box placed from a Search or Scan match of that text, and left where it was placed, removes the hidden copy where it is. A box you draw by hand, or one made with Duplicate Region, removes only the hidden text under the box itself; so does one placed where Resecta read the word from the page's picture because the hidden text spells it differently. A box from Search or Scan that you resize or move still removes the hidden copy it was placed for, and under its new place only the hidden text there. On such a page the hidden copy of the word you covered can stay in a Searchable export, where it can be selected, copied and searched. Verification reports it only if a detector in its final sweep flags it. The sweep reads the structured categories, and a detector can weigh the words around a number before it flags it; a name or an address is not swept. On some scanned pages the box itself can sit off the printed word: see KI-33.

**Workaround:** Export scanned documents with Secure Rasterization, which keeps no text layer.

---

### KI-26: Some Searchable Exports Keep the Real Export Time and iOS Version (Low)
**Affects:** Searchable Redaction

On Searchable exports that need a large fallback font, such as Chinese or Japanese text, the file keeps the real export time and iOS version instead of the fixed values: its Producer field names the iOS version and build, and its creation and change dates are the time of the export. Resecta looks for these values only in the last 256 KB of the file, and the large font can push them further from the end. No document content is affected. Document Metadata reports this as a warning: "Producer or timestamp fields were not rewritten to the fixed values". The results of such an export read Checks Failed, because Monospace Fonts reports the fallback font in the hidden text. When Verify Before Export is off, nothing reports it.

**Workaround:** Export the document again with Secure Rasterization (**More → Switch Mode**), or treat the iOS version and the export time as visible to whoever receives the file.

---

### KI-27: A Searchable Export Can Write Some Letters Twice in Its Hidden Text (Low–Medium)
**Affects:** Searchable Redaction

A Searchable export carries a hidden copy of the page's text, which is what makes the file searchable. Where the original file draws two letters as one joined shape, as some typeset documents do for "fi", "fl" and "ff", the hidden copy can carry both letters twice: "Benefit" is written "Benefifit". The same can happen to a Thai syllable written with the vowel sign ำ and to an emoji made of several joined emoji. In the exported file a search for such a word can find nothing even though the word is printed on the page, and text copied from the file carries the doubles. The Character Count check can then warn on a file that is otherwise correct. Some Devanagari and Tamil marks can be missing from the hidden copy. The picture of the page is not affected. In the cases tested, a box that touched any part of such a joined shape removed all of its letters from the hidden copy. <!-- LegalPhrases:safe -->

**Workaround:** If wrong text in the file would matter, export with Secure Rasterization, which keeps no text layer; the file then has no text to search or copy.

---

### KI-28: On a Scanned Page That Reads Sideways or Upside Down, a Multi-Word Search Can Miss Text That Runs onto the Next Line (Medium)
**Affects:** Search in text read from a picture (a scan, photo or screenshot)

On a scanned page whose print reads sideways or upside down as the page is shown, a name, address or other phrase that ends one line and continues on the next is not found by a search for the whole phrase. No box is placed on it, so it stays readable in the export. Verification does not report it: its Search Re-check looks for the phrase the same way, and a search that found nothing is not run again after export.

**Workaround:** Search each word of the phrase on its own, check each such page in the preview before sharing, and draw a box over anything Search missed.

---

### KI-29: In a Searchable Export, a Number Next to a Box Can Lose Digits in the Hidden Text (Low–Medium)
**Affects:** Searchable Redaction

The hidden copy of the page's text leaves out the characters closest to a box, on purpose: any character within three points (about a millimeter) of it, on a line the box touches. A number that stands beside a box, or on a line just above or below that the box reaches into, can lose the digits nearest the box that way, so "1290" can read "12" when it is copied or searched, while the page you see still shows the number, whole or in part. A word can lose the letters nearest a box the same way. No boxed text comes back, and no digit is added. In some files the hidden copy also loses the space between two words.

**Workaround:** If wrong text in the file would matter, export with Secure Rasterization, which keeps no text layer; the file then has no text to search or copy.

---

### KI-33: On Some Scanned Pages, a Box From Search or Scan Can Sit Off the Printed Word (High)
**Affects:** Secure Rasterization and Searchable Redaction (scanned pages that carry their own text: the printed word in either mode; a neighbouring word's hidden copy in Searchable Redaction only)

Some scanned PDFs carry a layer of text with the picture of each page, which is what makes them searchable. That layer does not always line up with the printed words: a word's hidden copy can sit a little to one side of where it is printed. On some scanned pages Resecta does not move a box from Search or Scan onto the printed word, for example where the scanner stored the page as many small pictures, or where the text lies under the picture and is not invisible. There a box placed from a Search or Scan match, and left where it was placed, covers the text's place, not the print. Part of the printed word, or all of it, can stay readable, and the hidden copy of a neighbouring word whose print the box covers can stay in a Searchable export, where it can be selected, copied, and searched. Verification can miss the printed part: every check can pass. Nothing in the app says that a box was not moved onto the print. In the editor, before you export, the box sits off the printed word, and the preview shows the print beside the fill.

**Workaround:** Before you export, check that each box on a scanned page covers the printed word. Where print shows beside a box, leave that box where it is and draw another box by hand over the print. Export scanned documents with Secure Rasterization, which keeps no text layer, and check each page in the preview before you share.

---

### KI-34: On a Photo or Scan, Search Can Miss a Number or Code Whose Digits Look Like Letters (Medium)
**Affects:** Search in text read from a picture (a scan, photo or screenshot), on iOS 26 and iOS 27

On a page that is a picture, such as a photo, a screenshot or a scan without its own text, Search reads the text with on-device text recognition and then corrects characters that are often read for one another: 0 and O, 1 and I, 5 and S, 8 and B. The correction can change a number or code that was read correctly, and the text you type is not changed the same way, so the search finds nothing. A number made only of the digits 0, 1, 5 and 8, on a line that is mostly words, can be turned into letters: "Suite 100" is searched as "Suite IOO", so a search for "100" does not find it. A short code that mixes letters and digits can turn either way: "4B" is searched as "48". A suite, room or case number, an amount such as "$1,000" and a member ID can be missed this way. A number that holds a 2, 3, 4, 6, 7 or 9 and no letters, such as most phone numbers, is not changed. No box is placed on a number Search does not find, so it stays readable in the export. When a search finds nothing at all, its message says how many pages were read by text recognition and to check those pages by eye; when the same number is found elsewhere in the document, nothing marks the one that was missed. A search that found nothing is not run again after export. <!-- LegalPhrases:safe -->

**Workaround:** On such a page, draw a box with Rectangle over each number or code you need removed, check each such page in the preview before sharing, and draw a box over anything Search missed.

Scan can miss a phone or Social Security number the same way: see KI-39.

---

### KI-35: A Search Match That Runs onto a Second Line Can Be Boxed on One Line Only (Medium)
**Affects:** Search (a name, address or other phrase that ends one line and continues on the next)

Where Search finds a name, address or other phrase that ends one line and continues on the next, it lists it as two rows with the same text, one for each line, and counts it as two matches. Each row is ticked and applied on its own. One line can then get a box while the other gets none: when you tick only one of the two rows, when you untick one of them after Select All, when you tap Apply with the search sheet lowered, which marks only the line you are on, or when you delete one of the two boxes afterwards. The line left without a box stays readable in the export. Verification does not report it as part of the match: its Search Re-check looks for the whole phrase, which the export no longer holds once one line is covered, and reads the line without a box as a match you chose not to redact; its OCR of Page Images check does not read the words on the line above or below a box as part of the match. Verification reports that line only if a detector in its final sweep flags it; a name or an address is not swept. <!-- LegalPhrases:safe -->

**Workaround:** When Search lists two rows on the same page with the same text, tick both before you tap Apply, or use Select All. With the search sheet lowered, step to the next result and apply it too. Before you tap Redact, check that each line of the phrase has its own box, and check the page in the preview before you share.

---

### KI-36: On Scanned Pages That Carry the Same Text, a Search or Scan Box Can Be Placed from Another Page (Medium)
**Affects:** Search and Scan, in both export modes (scanned pages that carry their own text, such as a scan made searchable by OCR)

Some scanned PDFs carry an invisible layer of text over the picture of each page, which is what makes them searchable. On such a page Resecta moves a box from Search or Scan onto the printed word, and it keeps what it read of a page so that it need not read it twice. It tells pages apart by their text, their size and their picture, not by which page they are. When two scanned pages carry exactly the same text, such as a sheet scanned twice or a form that repeats, and Resecta cannot tell their pictures apart, a box on the second page can be placed from the first page's printed words. If the two pages print the word at different places, the box sits off the word, and part of the printed word, or all of it, stays readable in the export; the word's hidden copy is still removed. The other page can be in the same document or in one you opened earlier without closing the app in between. In the editor, before you export, the box sits off the printed word. Verification can miss it: its OCR of Page Images check reports the word only when it reads the whole word outside every box, or at least three of its letters beside a box, and its Search Re-check places its own box the same way.

**Workaround:** Before you tap Redact, check that each box Search or Scan placed on a scanned page covers the printed word. Where it does not, draw another box by hand over the word. Export scanned documents with Secure Rasterization, which keeps no text layer, and check each page in the preview before you share.

---

### KI-37: Text Under an Annotation in the Original Is Visible in the Export, and Share Does Not Always Say So (Low–Medium)
**Affects:** Export, in both modes (documents with annotations over text, such as highlights, form fields, boxes or stamps)

An annotation, such as a highlight, a form field, a box or a stamp, is kept with the page, not drawn into the page itself. Resecta rebuilds the redacted copy from the page's own content in both export modes, so the exported file is built without annotations, and text an annotation covered in the original is visible in the export unless a redaction box covers it. For most annotations a notice at import says so, and when you tap Share, Resecta asks "Share with covered text?" and names the pages where an annotation covers text that no redaction box covers. That question can miss a highlight or a form field that is much larger than the text it hides: one drawn over a word or a line at its edge and clear over the rest of its area. The page is then not named at Share, and for a form field with no value the notice at import can be missing too. No check reports such text, because the checks read the exported file, where the annotation is gone and the text is ordinary page text.

**Workaround:** Before you tap Redact, draw a box with Rectangle over any text an annotation covers that must stay hidden. Check each such page in the preview before you share: the preview shows the redacted copy, which has no annotations. Changing the export mode does not help.

---

### KI-38: A Phrase That Continues on the Next Page Is Not Found by Search (Low–Medium)
**Affects:** Search

Search reads one page at a time. A name, address or other phrase that starts on the last line of one page and continues at the top of the next is not found by a search for the whole phrase. No box is placed on it, so it stays readable in the export. If the phrase appears nowhere else, Search shows its no-match message; if it does, nothing marks the one at the page break. Verification does not report it: its Search Re-check looks for the phrase the same way, and a search that found nothing is not run again after export.

**Workaround:** Search each word of the phrase on its own, check the last line of each page and the first line of the next in the preview before sharing, and draw a box over anything Search missed.

---

### KI-39: On a Photo or Scan, Scan Can Miss a Phone or Social Security Number Whose Digits Look Like Letters (Medium)
**Affects:** Scan in text read from a picture (a scan, photo or screenshot), on iOS 26 and iOS 27

On a page that is a picture, such as a photo, a screenshot or a scan without its own text, Search and Scan read the text with on-device text recognition and then correct characters that are often read for one another: 0 and O, 1 and I, 5 and S, 8 and B. KI-34 says what this does to Search. Scan makes the correction before its detectors read the line. A number in which every digit is 0, 1, 5 or 8, on a line that is otherwise mostly words, can be turned into letters: "Call 515-555-0181" is read by the detectors as "Call SIS-SSS-OIBI", so Scan does not list the phone number. A Social Security number can be missed the same way. A number with a 2, 3, 4, 6, 7 or 9 in any of its groups, such as "(208) 555-0147", or a date such as "01/05/1988", is not changed. No box is placed on a number Scan does not list, so it stays readable in the export. Verification can miss it too: its Detection Sweep runs the detectors again on the export, which reads the page the same way. A search for the number does not match it either.

**Workaround:** On such a page, draw a box with Rectangle over each phone, Social Security or other number you need removed, check each such page in the preview before sharing, and draw a box over anything Scan missed.

---

### KI-40: On a Scan Stored as Many Small Pictures, Search Does Not Read the Picture (Medium)
**Affects:** Search (scanned pages that carry their own text)

On a page with a text layer, Search also reads the page's images for text when one image holds at least 250,000 pixels, or at least half as many pixels as the page itself has at 100 dpi, or when the page's text layer is very short for its size. Some scanners store a page's picture as many narrow strips, each smaller than that, so on such a page Search reads the page's own text and does not read the picture, with or without Include OCR Pages. A word that is printed on the page but missing from that text, or spelled differently in it, is not found, and nothing in the app says the picture was not read. No box is placed on it, so it stays readable in the export. When you have applied at least one result of the same search, the check after export reads every page of the redacted copy for that term and can report it. A search that found nothing is not run again after export, so a word Search did not match anywhere in the document is not reported, and every check can pass.

**Workaround:** On a scanned document, look over each page for the words you searched for, check each such page in the preview before sharing, and draw a box over anything Search missed.

---

### KI-41: On Some Typeset Pages, a Multi-Word Search Can Miss Text on a Tightly Set Line (Medium)
**Affects:** Search on typed pages whose lines are justified, such as pages made with pdfTeX, which many LaTeX documents use

On such a page, the text the page carries can leave out the space between words on a tightly set line: "between Halvorsen Marine Supply, Inc." is read as "betweenHalvorsenMarineSupply,Inc." Search matches what you type against that text, so a search for two or more words, such as a full name or a company name, does not match them on that line. No box is placed there, so the words stay readable in the export. When you have applied at least one result of the same search elsewhere in the document, the checks after export read every page of the redacted copy for that text and can report it: OCR Check and Search Re-check can flag the page, and the results then read Needs Review. A search that found nothing is not run again after export, so text Search did not match anywhere in the document is not reported.

**Workaround:** Search each word of the name on its own with Whole word off, check each such page in the preview before sharing, and draw a box over anything Search missed.

---

### KI-42: In a Searchable Export, Colour Emoji Can Show Twice (Low)
**Affects:** Searchable Redaction (pages whose text includes colour emoji)

A Searchable export carries a hidden copy of the page's text, drawn over the picture of the page, which is what makes the file searchable. Colour emoji in that hidden copy are not hidden: they are drawn as visible pictures. On the exported page each such emoji can then show twice, once in the picture of the page and once from the hidden copy, and one can lie partly over the edge of a box. No text or emoji that a box covers is drawn this way. The results of such an export read Checks Failed: Font Verification reports the emoji font in the hidden copy.

**Workaround:** Export such a document with Secure Rasterization, which keeps no text layer; the file then has no text to search or copy.

---

### KI-43: A Word Drawn at Zero Size Can Get a Box Over Other Words (Low)
**Affects:** Search and Scan (typed pages that carry a word drawn at zero size, as in a tampered or unusual file)

A PDF page can carry a word drawn at zero size: the word is part of the page's text, but nothing of it is printed. When Search or Scan matches such a word on a page that also has printed text, the box is placed where PDFKit, the system's PDF reader, reports the word, and that box can lie over printed words you did not search for. When you apply it, those words are covered in the export. The box shows in the editor, and the covered words show in the preview before you share. No check after export reports it. When such a word starts where a printed line starts, a box for a printed word at the end of that line can also stop short of the word's last letter, so part of that letter stays printed in the export, with either export mode. The word cannot be read from what is left, and no check after export reports this either.

**Workaround:** Before you tap Redact, check that each box Search or Scan placed covers only what you searched for. Where one covers other words, select the box and drag its handles in, or delete it. Export such a document with Secure Rasterization, which keeps no text layer. Check also that each box covers the whole of the word you searched for; where one stops short, drag its handle out over the rest of the word.

---

### KI-44: On Text Drawn Back Over Itself, a Box Can Miss the First Letter of a Word (Low)
**Affects:** Search and Scan (typed pages where text is drawn back over text printed before it, as some form fillers and overprinted documents do)

**Fixed in 1.4.0 on pages whose drawing Resecta can follow letter by letter:** Search and Scan now take the box out to the word's first letter where the page draws it. Still affected: a page that draws any of its text in a font other than a simple Type 1 or TrueType font (a composite font, as many East Asian documents use, or a font drawn by its own procedures); a page whose text the system's PDF reader gives in another order than the page draws it; and a page built in one of a few rarer ways Resecta does not follow.

A PDF can move its drawing position back over text it has already printed, so that a word is printed partly over the one before it. When Search or Scan matches a word drawn this way, the box is placed where PDFKit, the system's PDF reader, reports the word, which can start after the word's first letter. When you apply it, that letter stays printed in the export, with either export mode. The rest of the word is covered. The checks after export do not report the letter as readable. Ordinary letter spacing does not cause this.

**Workaround:** Before you tap Redact, check that each box covers the whole of the word you searched for; where one stops short, drag its handle out over the rest of the word, or draw a box over it with Rectangle.

---

### KI-45: On a Scan, a Blank Line Through a Word Can Leave Part of It Uncovered (Medium)
**Affects:** Search and Scan on scanned pages

On a scanned page, Resecta fits each box to the word's ink in the scan. If a single row of the scan's pixels is completely white across the middle of a word, the box can be fitted to only the part of the word above that row. When you apply it, the lower part of the word's letters stays printed in the export, with either export mode, and the checks after export do not report it. On most real scans, a row through a word is rarely completely white.

**Workaround:** On scanned pages, before you tap Redact, check that each box covers the whole height of the word; where one does not, drag its handle down over the rest of the word, or draw a box over it with Rectangle.

On a page that is turned (see KI-47), don't use these steps; check the exported file instead.

---

### KI-47: On a Turned Page, a Box You Draw, Move or Resize Can Miss the Text (High)
**Affects:** Resecta 1.0 through 1.3.1, on PDF pages saved turned inside the file. Both export modes, Secure Rasterization and Searchable Redaction.

Some PDFs, often scans, store a page sideways or upside down with a note to turn it when shown. Resecta shows these pages the right way up. On such a page, a box you draw with Rectangle, or any box you move or resize, is exported in a different place from where it is drawn. With either export mode, the text under the box stays readable in the exported page, and the checks after export can report a pass.

Boxes placed by Search or Scan, and left where they were placed, are exported over the right text. On the same pages, though, Resecta draws them on screen in the wrong place.

**How to tell if a page is affected:** Use Search for a word on the page. If the box it places is not drawn over the word it found, the page is affected.

**Workaround:** On an affected page, don't draw, move or resize boxes, and don't use KI-45's steps. Use Search and Scan, and leave their boxes where they are placed, even though they look misplaced. Before you share any export, open the exported file and check that every box covers what it should.

**Fix:** 1.4.0 places every box on a turned page where it is drawn, and draws Search and Scan boxes over their text.

---

### KI-48: On a Very Large Page, a Very Thin Box Can Be Left Out of the Export (Medium)
**Affects:** Resecta 1.0 through 1.3.1, mostly on pages much larger than paper sizes, when the document has more than one box. Both export modes.

When you export, Resecta leaves out any box less than one thousandth of the page's height tall, or of its width wide. As long as the document has another box, it does this without saying so. The box stays on the page and in the count, and the text under it stays readable in the export. The checks after export may not report it.

On paper sizes up to A3, no box you draw is that thin. A box Search or Scan places is that thin only over one or two characters of print smaller than about 2 points. On a much larger page, such as one about 70 inches across, a box under about 5 points tall can be left out: a box Search or Scan places over small print, or, from 1.1, a box you draw at high zoom.

**Workaround:** On a large page, make each box at least as tall as normal text, and draw it with room around the words. Drag a Search or Scan box's handles out over the words around it. If the page is turned, see KI-47 first. Before you share the export, zoom in on it and check each small box.

**Fix:** 1.4.0 keeps every box at or above the size the export can fill, and does not start an export while any box would be left out; it names the box.

---

### KI-49: When an Address Appears Twice on One Page, Scan Can Miss the Second Copy (Medium)
**Affects:** Scan (an address that appears twice on one page, on typed or scanned pages)

When the same address appears twice on one page, Scan can place a box on the first copy and none on the second. No box is placed on the second copy, so it stays readable in the export. Not every page with a repeated address is affected.

**Workaround:** Where an address appears more than once on a page, check before you tap Redact that each copy has its own box, and draw a box with Rectangle over any copy that has none. Check each such page in the preview before sharing.

**Fix:** This is being fixed in a later version of Resecta.

---

### KI-50: On a Typed Page Resecta Finds It Cannot Read, the Search Re-check Can Miss a Box That Covers Its Match Only in Part (Low) <!-- LegalPhrases:safe -->
**Affects:** Resecta 1.3.0 and 1.3.1, the Search Re-check after an export, on a typed page that Resecta finds it cannot read and that has no picture Search also reads (KI-40 gives the rule), when the search ran with Include OCR Pages on. <!-- LegalPhrases:safe -->

Search reads such a page with text recognition, as it reads a scan, and places its boxes from that reading. After export, the Search Re-check runs each applied search again on the original pages and checks that the boxes cover the whole of each match. On such a page it reads the stored text instead. Where that text does not hold the word, or gives it no place on the page, the check finds no match there, counts the page as read, and does not report a box that covers its match only in part, as it does on other pages. The box itself is exported as placed; only the check is silent. On a page that also has such a picture, the check reads the page with text recognition as well and can report such a box. <!-- LegalPhrases:safe -->

**Workaround:** Before you tap Redact, check that each box covers the whole of the word you searched for; where one stops short, drag its handle out over the rest of the word, or draw a box over it with Rectangle.

**Fix:** 1.4.0 re-checks such a page the way Search read it: with text recognition, or, when Include OCR Pages is off, by saying that it could not read the page.

---

## Fixed

### KI-8: Duplicate Regions from Multiple Scan Runs (Low) — FIXED (entry moved 2026-10-01)
**Resolution:** Scan results are applied through the same path as search results, which skips a result that one existing region already covers whole, so applying the same scan twice adds no second region. The entry was stale.

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
