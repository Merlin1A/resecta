# Verification specification

## 0. Purpose and status

This is a target specification for the verification pass: what the pass establishes about an exported file, how it reaches its headline, and what it never does. It is derived from THREAT-MODEL.md (its assets, its adversaries, its trust boundaries, its accepted risks) and not from the code of any existing check, so that a verifier built from it does not inherit the producer's design. It is an engineering document, not a public promise, and it does not change anything README.md says the app does today. Every numbered rule ends with a `Status:` line reading `met today`, `partial` or `target`, each naming the check that makes it true or the later work that will. A rule marked `target` is NOT a claim that the app meets it today. Nothing here claims that verification can show the absence of a leak: the threat model's accepted risk on verification stands, and even the strongest tier below is a statement about named, closed properties of one file, not about everything a recipient might recover.

Terms used throughout:

- **The producer**: the part of the app that applies redaction and writes the exported file.
- **The verifier**: the part of the app that runs the verification pass. It reads its inputs and writes a report; it never writes the exported file.
- **Box**: a rectangle the user asked to redact, on one page, with an id.
- **Occurrence**: one place on one source page where a target (a query match, a scan hit, a user term) appears.
- **Cell**: one record of whether a property was inspected for one page or one box.
- **Observation**: one thing the verifier reports, with a kind and a location.

## 1. Inputs to the verification pass

The verifier sees exactly four inputs. It has no other channel to the producer: no shared object, no shared cache, no shared parsed document, no shared process state beyond these four values.

**1.1 The exported bytes.** The verifier reads the exported file once into memory and computes a SHA256 digest of that buffer. Every later check reads that one buffer. No check re-opens the file from disk, and no check reads a document object the producer built. The digest is recorded in the report as the subject of the report.
Status: target. Today the pass opens the exported file many times through the framework and records no digest; the shared copy is named by a digest that nothing compares with the report. The recorded-intent and one-read binding work makes it true.

**1.2 The recorded intent.** What the user asked for, recorded as the user asked it:
- the mode (image only, or with a rebuilt text layer);
- every drawn box BEFORE any filtering by the producer, with its page, its rectangle in page space and its origin (drawn by hand, placed from a search match, placed from a scan category, placed for a face or a whole page);
- the typed queries and regular expressions, each with its matching options;
- the scan categories and the user terms;
- every occurrence the user deliberately kept (deselected in search or scan), by page and location;
- which box was placed for which occurrence;
- the export settings (resolution, fill colour, any setting that changes what is drawn).

The intent is held in memory only. It is never written to disk outside tests.
Status: partial. Today the pass receives the burned boxes (after filtering), the applied-search records with the scan deselections, the recorded terms and the per-page modes. Missing: the boxes before filtering, the typed-search deselections, the box-to-occurrence pairing and the settings. The verdict-function change adds the kept endings; the recorded-intent work adds the typed-search deselections and the rest.

**1.3 The source bytes.** The verifier opens the original file itself, from its own copy of the original bytes, and computes its digest. It never reads a re-serialized copy, a cached page or a parsed document handed over by the producer. If the source cannot be read in full (for example a password-protected original that stays locked), every cell that needs it is recorded as not inspected with that reason, and the pass reports that it did not run those checks; it never treats them as passed.
Status: partial. Today only the coverage check reads the original, through a re-serialized copy the producer hands over; a locked original is reported as coverage not run, never as passed. Opening the source itself from its own bytes is the own-reference-data work.

**1.4 The producer's claims.** Everything the producer states about its own work travels in one labelled value: per-page mode, the burned box ids, the refused box ids (boxes the producer dropped, for example as too small), the ink-growth rectangle of each box, the text-removal rectangles, the terms the producer recorded (each labelled with its origin: matched text, typed, captured under a hand-drawn box), the producer's per-page digests, and the writer profile (the fixed producer tag, the fixed dates, the rule for the file identifier, the allowed font names, the expected shape of a page). The verifier may check any claim; it never trusts one. Data the producer derived from the document (matched text, captured words, the burned set, its digests) can feed only the self-check tier (rule 2.4) or be checked against the verifier's own reading. A claim can never fill a required cell, except the target-coverage cell under rule 2.4 until the verifier derives its own reference, and can never lower a headline.
Status: target. Today the per-page mode claim decides which pages the text-layer checks judge, and the producer's digests are the reference of the count and lineage checks, with no label on either. The recorded-intent work carries the claims as one labelled value; the verdict-function change tags the tiers. The target-coverage clause of rule 2.4 is dated 2026-11-03; the own-reference-data work retires it.

## 2. Properties

Each property names what the verifier establishes, the method it uses, what it never trusts, and its tier (section 5). The methods are the verifier's own: its own byte-level walk of the PDF with stream inflation; its own content-stream interpretation with text-matrix tracking; its own geometry from the output page box; its own render of the source page; pixel reading of the shipped raster; its own text recognition of its own render; a normalizer written from this specification. On the device the verifier uses Apple's frameworks only; where one of them is also used by the producer, the verifier uses a second route for the same question and reports a disagreement (rule 5.4).

**2.1 P1, container closure.** The exported file holds exactly the objects its rendered pages need, and nothing that carries source content.
- *Establishes:* one revision (one cross-reference section, one trailer, one end-of-file marker, no bytes after it); every object reachable from the trailer through the catalog and the page tree to what the pages draw, and no object outside that set (no dead, orphaned or incrementally updated object); no attachments, scripts, actions, annotations, form fields, outlines or metadata streams; an information dictionary whose keys and values match the writer profile; a file identifier the verifier recomputes from the bytes by the stated rule; every string and every inflated stream searched for the verifier's own reference text from the source (rule 2.3), in the encodings a PDF string can carry.
- *Method:* the verifier's own byte-level walk: it parses the cross-reference data, enumerates every object by offset and by scan, inflates every stream it can, and compares the reachable set with the full set.
- *Never trusts:* the writer profile as a description of the file (it is the expected shape, checked against the bytes); any parsed view another component produced.
- *Unknown structure:* an object type, filter, key or construct the walk does not model is a `structure unknown` observation, never a pass and never silently skipped. Content-bearing structure (anything above that carries source text or source pixels) is a `structure content-bearing` observation.
- *Tier:* established.
Status: partial. Today: a denylist of catalog keys, name trees and page actions; the end-of-file marker count; the information dictionary and the fixed producer values; the file identifier recomputed through the producer's own routine; a byte search of string objects outside streams for the recorded terms. Missing: the reachability walk, stream inflation, the unknown-structure observation (a construct outside that list is not reported), an identifier rule of the verifier's own. The established-tier work makes it true. This release: the cell is inspected by that list of known parts, associated files among them, through the system's PDF reader; the scope statement carries the limit in words: parts not on the list are not reported, and an object the pages never draw is not detected.

**2.2 P2, removal.** Under every drawn box, nothing of the source survives in the exported file.
- *Raster:* the verifier decodes the shipped page image and maps each drawn box onto it with its own geometry, computed from the output page box, the drawing matrix that places the image and the source page geometry (rotation, crop). Every pixel inside the mapped box must read as the fill colour within a stated tolerance for the image encoding; the tolerance is the cell's sensitivity. Where the producer claims an ink-growth rectangle, the verifier checks that the grown area is painted too; the required area is never smaller than the drawn box, whatever the claim says.
- *Text layer:* the verifier interprets every content stream itself, tracking the text matrix, the font size, the character spacing and the rendering mode, and computes for every glyph its drawn cell: the glyph's advance width by the height the font's own ascent and descent give at that size. The glyph's core is that cell with a fraction of its height removed at the top and at the bottom, the fraction being the font's descent divided by its ascent plus descent, or one quarter when the font's metrics cannot be read; on a vertical run the cell and the core are measured along the run. A glyph whose core has its centre inside a drawn box is a `defect inside a box`. A glyph whose cell crosses a box's edge while its core's centre lies outside the box is a `note` that records the overlap: the rebuilt layer sets each surviving character on a uniform grid, which can carry it across an edge it did not touch on the original page. A text object whose starting point lies inside a drawn box is a `defect inside a box`, whatever its font. On a page the verifier's own walk reads as image only, any text object at all is an observation.
- *Text versus image:* what the text layer says must be what the pixels show. Every text-layer run must lie over inked pixels; a run over pixels of the fill colour or of uniform background is an observation. Where the verifier's own recognition of the shipped raster reads a line differently from the text layer, that is an observation.
- *Never trusts:* the burned set, the text-removal rectangles, the per-page mode claim. A box the producer refused or did not burn is judged exactly like any other drawn box.
- *Tier:* established for raster and text layer under each box; advisory for the agreement between text and recognition.
Status: partial. Today: the text layer under a box is judged from the framework's glyph bounds using the producer's own box-to-page map; the shipped image is read by text recognition, not by pixels; text versus image is not compared. Missing: the pixel reading of the raster under each box, the verifier's own content-stream interpretation and geometry, the agreement check. The established-tier work makes it true. This release: the boxes judged are the producer's burned set, so a box the producer refused is not reported; the text-layer cell is judged through the producer's own box-to-page map; a page the intent made image-only is tested for any text the system's PDF reader extracts, and text hidden in a page's drawing instructions that the reader does not extract is not read, which the scope statement says; readable text under a box on such a page is a defect by the verifier's own recognition; the pixel reading under a box arrives with the pixel-tier work's block audit. The text-layer check applies this rule today with the producer's own geometry; a reader built from this rule agrees with the producer's by construction, so a disagreement on a file is a route disagreement (rule 5.4).

**2.3 P3, target coverage.** Every occurrence the intent targeted has a box that covers it.
- *Reference data:* the verifier derives its own reference from the SOURCE: its own text extraction (its own content-stream interpretation of the source pages) and its own recognition of its own render of each source page. It runs each typed query and regular expression with the recorded options, each user term, and its own recognizers for the structured scan categories, over that reference, through a normalizer written from this specification (Unicode compatibility forms, case, width, diacritics, confusable characters, dash, quote and space variants, a word broken by a hyphen at a line end). Terms the producer recorded are checked as a labelled extra reference set; they are never the only reference.
- *Containment:* for each occurrence, the verifier tests whether its glyph rectangles lie inside a drawn box. An occurrence with no box is `residue outside any box`. An occurrence a box only partly covers is `defect box short`.
- *Ink past the edge:* on its own render of the source, the verifier looks for glyph ink that crosses the edge of a drawn box. Glyph ink printed past a box's edge is a `defect box short`, not a note. Long rules and underlines are not glyph ink. A box drawn by hand with no recorded target is examined at its edges only: text that runs on beside the box, between letters or between words, is not detected by this rule, and the scope statement says so.
- *Kept occurrences:* an occurrence the intent records as kept is listed as `kept`, matched by location, and never flagged. Location means rectangle overlap on the same page; equal text alone never pairs a kept occurrence with a place. An occurrence any box touches is judged for coverage and never listed as kept; a kept line piece of an occurrence another piece of which is boxed is not kept: `defect box short` stands (rule 4.3). A kept ending (the trailing characters the intent keeps of one occurrence) is the expected uncovered part of that occurrence, on its trailing side only: more left uncovered is `defect box short`, fewer is a `note`, and an ending the recognizer cannot read leaves the cell not inspected.
- *Across pages:* text the verifier reads under a hand-drawn box that also appears unboxed elsewhere in the document is `possible`.
- *Limits made visible:* a term too short to judge, a category the verifier has no recognizer for, and text the recognizer detects but cannot read are each recorded in the scope statement or as a not-inspected cell, never counted as clear.
- *Never trusts:* the producer's matcher, its normalizer, its recorded terms as complete, its pairing of boxes to occurrences without checking the geometry.
- *Tier:* advisory. A check that fired only on producer terms is advisory with basis `producer-terms`. The edge-ink rule, which rests on the verifier's own render and on no term, is established once its false alarms on correct files are measured as zero on named fixtures, else it is advisory.
Status: partial. Today the coverage check re-runs the producer's own search engine over the original and pairs its results with the boxes by occurrence; scan deselections are subtracted in the sweep, typed-search deselections are not; glyph ink past a box's edge is read only through text recognition of a redacted term's start or end beside the box, never from pixels; a term too short to check is named in a check's own tail line, not in a cell. The pixel-tier work adds the edge-ink defect; the verdict-function change adds kept occurrences from scans, kept endings and the too-short cell, and typed keeps arrive with the recorded-intent work; the own-reference-data work replaces the producer's engine as the reference. This release: the edge-ink rule runs on every drawn box, and the between-letters and between-words cases are named in the scope statement as not detected; the comparison against the original is made on the pages that carry the request's boxes and their neighbouring pages (a match that wraps across a page break is judged whole), each cell recording which pages were compared, and a page without a box for the request is judged by the read of the exported file, which covers every page.

**2.4 P4, self-check.** The producer's own re-runs are reported, as a separate tier.
- *Includes:* the producer's search re-check on the output, its detection sweep, its coverage arithmetic and its per-page digests.
- *Effect:* a self-check observation can add to the report and can raise the headline. It can never lower one, never fill a required cell at the established tier, and never produce VERIFIED on its own. Until the verifier derives its own reference for target coverage (rule 2.3), the required target-coverage cell may be filled at the self-check tier: the cell records that it was inspected at the self-check tier on the producer's terms, and the headline then always carries the scope line that names the producer's own search engine as the reference (dated 2026-11-03; retired by the own-reference-data work). A self-check that passed is never shown as evidence for a property the verifier established or failed to establish.
- *Tier:* self-check; the producer's digests echoed back are producer postcondition.
Status: partial. Today the re-check, the sweep, the coverage arithmetic and the digest checks run, but as ordinary rows of one fold with no tier, so a reader cannot tell them from a verifier-established property. The verdict-function change tags them as the self-check tier and records the target-coverage cell as filled at that tier, under the dated clause above.

**2.5 P5, side channels of the pass itself.** The pass leaves nothing behind and discloses nothing.
- Nothing is sent off the device during verification; the verifier holds no network client.
- No temporary file the pass writes outlives the pass, on success, on failure and on cancellation; temporary files live in the session's own workspace.
- The report carries no text read from the document (nothing from under a box, no matched text) and no source file name. The user's own typed terms may be shown to the user on the results screen; nothing that leaves the app carries them. Before the report is shown, the verifier scans its own serialized report for its reference text from under the boxes; a hit removes the field and records a note.
- Diagnostic logs follow the same rule as the report.
- *Tier:* established for the report scan; the network and file rules are properties of the verifier itself, held by its construction and checked by tests.
Status: partial. Today a lint refuses the named networking symbols in the shipping source, the per-session workspace holds the temporary files, and the share confirmation shows no matched text. Missing: the report scan for reference text, and a test that holds diagnostic logs to the same rule as the report. The verdict-function change fixes the report's fields; the self-check-tier work adds the scan.

**2.6 P6, what was previewed is what was exported, and what is shared is what was verified.**
- *Previewed versus exported:* page count, each page's size, each page's rotation, the raster covering the full page box on every page (the drawn-full-page property), and the fill colour, each read by the verifier from the exported bytes and compared with the intent and with the source geometry.
- *Verified versus shared:* the digest of the file handed to the share sheet equals the digest the report names (rule 1.1). If the file changes after the pass (for example the user edits a box), the report no longer describes it and the app treats verification as not run for the new file.
- *Never trusts:* the producer's page-size or page-count claims.
- *Tier:* established.
Status: partial. Today the page count is compared before any other check, and every box edit deletes the exported file (a delete that fails leaves it for the sweep) so a stale report cannot describe a new one. Missing: page sizes, rotation, the full-page raster property and the fill colour read from the bytes; the digest the report names compared with the shared file. The verdict-function change adds the geometry cells; the one-read binding adds the digest. This release: only the page count is compared, against the count the app read when it opened the original, and the scope statement names the rest as not compared; the digest of the shared file is shown and compared with nothing.

## 3. Coverage cells

**3.1 The lattice.** For every (property, page) and every (property, box) the report holds exactly one cell, which is one of:
- `inspected`, with the method used and its sensitivity (for example the pixel tolerance, the recognition level, the normalizer's forms);
- `not inspected`, with a reason (source locked, parse limit reached, recognizer could not read, check did not complete, out of memory, cancelled);
- `not applicable`, with a reason (for example the text-layer cells of a page the verifier's own walk reads as image only).
Status: target. Today the report holds one status per check with page numbers for the winning arm only, and no cell. The verdict-function change introduces the cells.

**3.2 Required cells.** Each cell carries a `required` flag. The required set is computed from the intent and the mode before any check runs: P1 and P6 for every page; P2 raster and P2 text layer for every drawn box; P3 for every page when the intent holds any query, term or scan category; P3 for every box with a kept ending. The edge-ink cell of a drawn box is held in every run but is not in the required set: a box whose edge cannot be examined is listed in the scope statement, never an INCOMPLETE on its own.
Status: target. Today nothing to check folds to a pass inside each check. The verdict-function change computes the required set from the intent before any check runs. This release: the set is computed from the burned boxes, the page count, the applied searches and scans, and the kept endings.

**3.3 Not applicable rests on the verifier's reading.** A cell may be marked `not applicable` only on the strength of the verifier's own reading of the bytes. A claim alone (for example the producer's page-mode claim) never makes a cell not applicable.
Status: target. Today the per-page mode claim alone decides which pages the text-layer checks skip; a page declared image-only that carries text is still read by the checks that run over the whole output. The verdict-function change stops a claim from marking a cell; the own-reference-data work gives the verifier its own page reading. This release: the mode claim still picks which pages the text-layer checks judge, and a page claimed image-only is tested for any text at all, which is the verifier's own reading.

**3.4 A required gap is always visible.** A required cell that is not inspected makes the headline INCOMPLETE at least. No pass elsewhere, no self-check result and no claim can hide it.
Status: target. Today a check that could not run reports a warning that the fold ranks below attention, and the results screen relabels it; no INCOMPLETE headline exists. The verdict-function change makes it true.

**3.5 A check that does not complete.** A check that throws, times out or is cancelled leaves its cells `not inspected` with that reason; such a cell is never marked `inspected`.
Status: partial. Today a cancelled check is marked skipped and a check that throws is marked failed, never passed; a check that stops at the first unreadable page reports a warning and leaves the later pages unmentioned. The verdict-function change turns each into not-inspected cells with the reason. This release: a page whose dictionary cannot be read, the pages at and after which the font check stops for want of resources, and a page the text check cannot read each leave their cells not inspected, never silent and never outranked by another page's result.

## 4. Observations

**4.1 Kinds.** Every observation has exactly one kind:

| Kind | Meaning |
|---|---|
| defect inside a box | source content survives under a drawn box: a pixel not the fill colour, a glyph, a text object or invisible text |
| defect box short | a box covers only part of a targeted occurrence, or glyph ink is printed past a box's edge |
| residue outside any box | a targeted occurrence has no box |
| kept | an occurrence the user deliberately kept, listed for the record |
| possible | something a human eye should look at: a fuzzy match, an unboxed repeat of boxed text, text and image that disagree |
| note | context that changes nothing: a refused box, a term too short, a canary result, an item of a kind the intent did not ask for |
| structure content-bearing | the container carries something that holds source content, or active content the writer never emits (a script, an action, a launch) |
| structure unknown | the container carries something the verifier does not model |

Status: target. Today a check reports one status and one message; the kinds exist only as wording inside messages. The verdict-function change introduces the kinds.

**4.2 Fields.** Each observation carries its page; its rectangle where known; its box id where known; its occurrence reference where known; its kept count where it has one; its tier; and its basis tags (rule 5.3). It never carries text read from the document (rule 2.5).
Status: target. Today no rectangle, box id or occurrence reference reaches the report; the checks compute them and drop them. The verdict-function change carries them.

**4.3 Many, not one.** A check may emit any number of observations. One observation never replaces or suppresses another; an observation on one page never masks one on another.
Status: target. Today each check folds its arms to one status and keeps only the winning arm's pages. The verdict-function change makes every check emit all of its observations.

## 5. Tiers and basis

**5.1 Tiers.**

| Tier | What belongs there |
|---|---|
| established | closed-world properties the verifier establishes on the shared bytes with its own methods: container closure, one revision, removal in the raster and in the text layer, the digest |
| advisory | coverage, recognition, the sweep, and anything resting on producer terms |
| self-check | the producer's own re-runs |
| producer postcondition | the producer's digests, echoed |

Established means only that the named property holds of these bytes by the verifier's own reading; it is not a statement that nothing can be recovered by other means.
Status: target. Today no tier exists. The verdict-function change tags every check; the established tier is filled by the established-tier work. This release the established tier holds: the page count; no text, annotation, outline or form on a page the intent made image-only; the structure's list of known parts; the writer's fonts; the information dictionary's keys; readable text under a box on a page the intent made image-only; the block audit of the raster under a box where it lands; and the edge-ink rule under its condition in rule 2.3. Each reads through the system's PDF reader or text recognizer, which the producer also uses, and records that as its route, a dated departure from the verifier's own walk; before its plain-words sentences are shown, its false alarms on clean files are measured as zero and its misses per seeded class are measured beside them and named in the scope statement.

**5.2 Tier is fixed by method and basis.** A check's tier follows from its method and its basis, not from its importance. A check moves down a tier, never up, when its basis weakens.
Status: target. Follows the tier tags of the verdict-function change.

**5.3 Basis tags.** Every check and every observation carries one or more of: `intent` (rests on the recorded intent), `verifier-derived` (rests on the verifier's own reading of the source or the output), `producer-terms` (rests on terms the producer recorded), `writer-profile` (rests on the expected shape of the file), `claim` (rests on another producer claim). A check that fired only on producer terms is advisory, never established.
Status: target. Today the term-dependent checks do not record whether they rested on producer terms. The verdict-function change adds the basis tags.

**5.4 Route tags.** Every check names its route (for example the verifier's byte walk, or a framework parser used as a second route). Where two routes answer the same question differently, the result is at least NEEDS ATTENTION, never VERIFIED, and both answers appear in the report.
Status: target. Today each question has one route. Second routes arrive with the established-tier and own-reference-data work. This release: every check records its single route: the system's PDF reader, the system's text recognizer (which the producer also uses), or the producer's own engine.

## 6. The headline

**6.1 One pure function.** A single function over (intent, claims, cells, observations) returns the headline and a scope statement. It reads nothing else, keeps no state, and gives the same result for the same inputs. No other code computes or adjusts a headline.
Status: target. Today one routine in the engine folds the statuses and the results screen re-derives labels from them. The verdict-function change replaces both with the one function and deletes the old fold.

**6.2 Order.** FAILED over NEEDS ATTENTION over INCOMPLETE over VERIFIED. The headline is the highest that any rule below reaches.
Status: partial. Today the order is failed, attention, warning, passed; no INCOMPLETE exists and could-not-verify is relabelled on screen. The verdict-function change makes it true.

**6.3 The rules.**

| Input | Headline it reaches |
|---|---|
| defect inside a box, defect box short, structure content-bearing | FAILED |
| residue outside any box, possible, a disagreement between routes | NEEDS ATTENTION |
| structure unknown | INCOMPLETE |
| a required cell not inspected | INCOMPLETE |
| kept, note | none: listed, never flagged |
| none of the above, every required cell inspected (a target-coverage cell inspected at the self-check tier counts, under rule 2.4, and the headline is then shown with its scope line, never without) | VERIFIED |

Self-check observations enter the same table and can raise the headline; nothing from the self-check tier can lower it.
Status: partial. Today a recorded term read under a box fails; a text-layer survivor under a box reads as needs-review; a note and a nothing-to-check row have no effect on the fold; kept occurrences are not represented. The verdict-function change makes the table true.

**6.4 Inspect only.** For a run with no export (the user inspects a file), the headline is INSPECTED, with no verdict word, and the scope statement and the observations are shown as for any run.
Status: target. Today a verify-only run exists only for a skipped report with an output; inspecting a file without exporting is later work, after the recorded intent carries the purpose.

**6.5 The scope statement.** Every headline comes with a scope statement that lists: the pages read; the boxes checked for ink and the boxes checked for edges; the terms checked and the terms too short to check; the categories swept and the categories not swept (names and addresses are among those not swept until a recognizer for them exists); the boxes drawn by hand, which are checked at their edges only; faces, which no check reads; the word forms a query does not match; the kept endings; content of the original not carried into the file, such as filled form fields; the count of items of kinds the intent did not ask for; the sensitivity the sweep inherited from the scan and the count of never-flag terms it left out; the parts of the file read through the system's PDF reader and text recognizer, which the producer also uses, and what they do not read in this release (parts of the structure not on the list of known parts, text hidden in a page's drawing instructions, and page sizes, rotation and fill colour, which are not compared); and what was not inspected, and why. VERIFIED is never shown without its scope statement.
Status: partial. Today each check carries its own detail sentence (pages read, terms too short, categories not swept); no one statement collects them. The verdict-function change adds the scope statement.

## 7. Disclosure, never enforcement

**7.1 Shown in plain words.** Every headline, its scope statement and its observations are shown to the user in plain words, on the results screen and again where the user shares. The scope statement accompanies the headline on the results screen and on the share confirmation, and the file's digest is never shown under VERIFIED without the scope statement in the same view.
Status: partial. Today the results screen and the share confirmation show every status and its message. The plain-words tiers are the clear-disclosure change. The share control sits on the results screen, so that screen is also where the user shares: a confirmation re-shows the headline and the observations whenever one opens, and on VERIFIED the scope statement is in view at the share control, not below it.

**7.2 No verdict withholds the file.** No headline and no observation blocks, refuses, disables, renames or withholds the exported file, and no headline changes what the producer wrote. What the user does with the file is the user's choice. A confirmation that lists what the verifier reported and lets the user continue to share is disclosure, and is within this rule.
Status: met today. Export is never blocked: sharing checks only that the file exists, and every confirmation lets the user continue. Share waits while the pass runs; that is a state of the run, not a verdict. Kept so by the maintainer's standing decision.

**7.3 Words on screen.** The words shown on screen are app copy, decided separately and held to the app's own copy rules. This specification fixes only the code names `established` and `advisory` and the headline names used in code; it fixes no user-facing wording.
Status: met today as a rule of this document; the code names land with the verdict-function change and the words with the clear-disclosure change.

## 8. What the producer asserts and what the verifier checks

**8.1 Every claim is checked or ignored, never relied on.** For each claim the producer makes, the table names what the verifier checks it against and what it never takes from it. A claim with no row here does not reach the verifier.
Status: partial. Today the per-page mode claim picks the pages the text-layer checks judge, the digests are the reference of the count and lineage checks, and the file identifier is recomputed through the producer's own routine; the writer profile is compared with the bytes. The recorded-intent work labels the claims; the verdict-function change and the established-tier work check them as the table says.

| Claim | Checked against | Never trusted for |
|---|---|---|
| per-page mode (image only, or with a text layer) | the verifier's own walk of each page's content | marking text-layer cells not applicable |
| burned box ids | the drawn boxes in the intent, each judged under P2 | narrowing the set of boxes P2 inspects |
| refused box ids | the drawn boxes; each refused box is still judged under P2 and listed as a note | removing a box from the report |
| ink-growth rectangles | the shipped raster: the grown area must read as painted | shrinking the area that must read as the fill colour |
| text-removal rectangles | the verifier's own glyph rectangles in the output text layer | deciding where text may remain |
| recorded terms, by origin | the verifier's own reference text from the source | being the only reference for P3 |
| box-to-occurrence pairing | the verifier's own containment geometry | deciding an occurrence is covered |
| per-page digests | the verifier's digests of the same pages, reported as producer postcondition | any established-tier property |
| writer profile | the information dictionary, the file identifier recomputed from the bytes, the fonts and page shapes found by the byte walk | describing what the file contains |
| source digest and page count | the verifier's own digest and page count of the source it opened | choosing which source to read |
| output page sizes, rotation, raster properties, fill colour | the verifier's own reading of the exported bytes and the intent | any P6 comparison |
| the producer's re-check, sweep and coverage results | nothing: reported in the self-check tier | lowering a headline or filling a cell |
| facts about the original read at import (filled form fields; text hidden under an annotation) | nothing yet: reported as `possible`, for a human eye | filling a cell or lowering a headline |

## 9. Out of scope of this document

- **Process isolation.** Running the verifier, or the parsing of an untrusted import, in a separate process. The same Apple frameworks would run on both sides; the threat model accepts that those frameworks parse untrusted input inside the app's process.
- **Non-Apple tools.** Independent PDF parsers, renderers and text recognizers that are not Apple frameworks belong to the continuous-integration oracle that runs off the device, not to the verifier in the app.
- **The harness that measures the verifier.** How the verifier's miss rate is measured against seeded leaks, how independence between the producer and the verifier is measured, and the test corpus that does it.
- **User-facing words.** The copy on the results screen and at the share confirmation (rule 7.3).
- **Hostile input to the verifier as an attack surface.** The verifier inherits the size and page limits of the import boundary, and a parse it cannot complete is `not inspected`; hardening beyond that is a separate document.
