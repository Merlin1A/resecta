import Foundation
import PDFKit
import Vision
import ImageIO
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// Layer 2 (OCR on Output), the check half: the observation and verdict types, the
// pure per-page classifier and its geometry, the term-containment rules, and the
// page-image and JPEG-stream extraction helpers. Moved whole from VerificationEngine.swift;
// no line inside a moved body changes.

extension VerificationEngine {

    // MARK: - Layer 2: OCR on Output

    /// A single Layer-2 OCR observation, reduced to a plain value type so the
    /// classification logic is unit-testable without Vision. Boxes are normalized
    /// (0–1, **bottom-left origin**) — the SAME convention as
    /// `RedactionRegion.normalizedRect` (`RedactionRegion.swift:33`). The Vision
    /// `boundingBox` → region mapping is the IDENTITY, NOT a y-flip (pinned
    /// by the coordinate-convention guard tests).
    /// Part A: per-box, full-RGB fill statistics for the chroma-aware
    /// fill-consistency guard. Computed over the IN-REGION PORTION of the box
    /// (box ∩ region-rect, Option A — see `enrichWithFillSamples`) against the
    /// region's self-calibrated fill colour. All values are 0…1; distance is the
    /// per-channel (Chebyshev) RGB distance from the fill, so a coloured glyph
    /// whose luminance ≈ the fill (e.g. navy on black) still reads as contrast — a
    /// luminance-only test would mis-classify it as fill. See `isFillConsistent` /
    /// `boxFillSample`.
    struct BoxFillSample: Sendable {
        /// Share of SAMPLED pixels (the in-region portion, box ∩ region-rect)
        /// within `fillDistance` of the fill colour.
        let fillFraction: CGFloat
        /// Share at/over `contrastDistance`. The contrast band reaches DOWN to at
        /// least the fill band's edge (`contrastDistance <= fillDistance`), so no
        /// pixel falls in a gap between the two (the no-dead-zone invariant).
        let contrastFraction: CGFloat
        /// Largest single-pixel distance from the fill — the outlier floor: the
        /// dark/contrasting core of any real glyph deviates strongly even when it
        /// is too thin to move `contrastFraction`.
        let maxDeviation: CGFloat
    }

    struct OCRHit: Sendable {
        /// Line-level observation box; the conservative intersection fallback.
        let box: CGRect
        /// Per-word boxes when obtainable; empty → use `box`.
        let wordBoxes: [CGRect]
        /// Top-candidate recognized string, for sensitive-term matching.
        let text: String?
        /// Observation confidence (already ≥ `ocrConfidenceThreshold` for any
        /// constructed hit); re-checked against the FAIL gate at classification.
        let confidence: Float
        /// Part A: per-box full-RGB fill samples, index-PARALLEL to
        /// `inRegionCandidateBoxes(of:)`. EMPTY ⇒ fill is unknown ⇒ the classifier
        /// excludes nothing and behaves exactly as before (keeps the pure
        /// classifier unit tests, which never set this, unaffected).
        let boxFill: [BoxFillSample]

        /// `boxFill` defaults to empty so every existing construction
        /// (`OCRHit(box:wordBoxes:text:confidence:)`) is unchanged; only the
        /// fill-sampling site supplies it.
        init(box: CGRect, wordBoxes: [CGRect], text: String?, confidence: Float,
             boxFill: [BoxFillSample] = []) {
            self.box = box
            self.wordBoxes = wordBoxes
            self.text = text
            self.confidence = confidence
            self.boxFill = boxFill
        }
    }

    /// Per-page Layer-2 verdict. Classified per page with priority
    /// `sensitiveTermInRegion > textInRegion > fillArtifactInRegion >
    /// sensitiveTermOutsideRegions > textOutsideRegionsOnly > none`; the
    /// cross-page layer fold (`foldLayer2PageOutcomes`) then places the
    /// attention and warnable out-of-region arms ahead of the fill-artifact
    /// note — see the priority-fold comment there.
    /// `fillArtifactInRegion` (Part A) is an in-region OCR hit proven to be a
    /// Vision hallucination off the SOLID fill — it DEMOTES the would-be
    /// FAIL/WARN to an informational note, and never silences a hit: it
    /// outranks `textOutsideRegionsOnly` in both orders, so a page carrying it
    /// can never fold to a clean PASS. `sensitiveTermOutsideRegions` marks a
    /// page where a sensitive term — the matched text of a region the user
    /// applied — is readable OUTSIDE every region: the redaction itself is
    /// intact, but an un-redacted occurrence of the term survives.
    /// `pageBucket(for:effectiveMode:)` maps it to its own bucket on BOTH
    /// page modes and the fold reports ATTENTION with the matched term texts
    /// (`outsideRegionTermTexts`) threaded to the results row — the tier
    /// Layer 3 and the Search Re-check give the same condition; the user's
    /// remedy is a text search. `textOutsideRegionsOnly` is the page's own
    /// un-redacted content and stays informational.
    enum PageOCRFinding: Sendable, Equatable {
        case sensitiveTermInRegion
        case textInRegion
        case fillArtifactInRegion
        case sensitiveTermOutsideRegions
        case textOutsideRegionsOnly
        case none
    }

    /// Builds the Layer-2 region set through the SAME sliver
    /// predicate the fill path uses (`PipelineCoordinator.buildPDFPageData`):
    /// drop regions with `normalizedRect.width/height <= 0.001`, clamp survivors.
    /// Painter and verifier then see one region set — a sub-threshold sliver the
    /// engine refuses to fill never produces a Layer-2 WARN/FAIL describing a
    /// region that was never redacted.
    static func layer2RegionSnapshot(_ regions: [RedactionRegion]) -> [RedactionRegion] {
        regions.compactMap { region in
            guard region.normalizedRect.width > 0.001,
                  region.normalizedRect.height > 0.001 else { return nil }
            var clamped = region
            clamped.normalizedRect = region.normalizedRect.clampedToNormalized()
            return clamped
        }
    }

    /// Pure Layer-2 classifier. An OCR hit is "in region" when any of
    /// its boxes has at least `inRegionCoverageThreshold` of its own area inside
    /// a region's `normalizedRect` (identity space) — meaningful containment, not
    /// a sliver edge touch — AND, for a polygon region
    /// the box intersects the vertex polygon itself: the rect is only
    /// the polygon's bounding box, and text inside bbox-minus-polygon is page
    /// content the user chose to keep. FAIL when a sensitive term is
    /// readable inside a redacted region; WARN for any other in-region text; text
    /// only outside regions is the page's own (un-redacted) content. No Vision
    /// dependency — fully unit-testable.
    /// `[String]` compatibility overload: bare string terms keep their
    /// substring semantics (no boundary flag), exactly the pre-model behavior.
    @_disfavoredOverload
    static func classifyPageOCR(
        hits: [OCRHit],
        pageRegions: [RedactionRegion],
        sensitiveTerms: [String]
    ) -> PageOCRFinding {
        classifyPageOCR(
            hits: hits, pageRegions: pageRegions,
            sensitiveTerms: sensitiveTerms.map { SensitiveTerm(text: $0) })
    }

    static func classifyPageOCR(
        hits: [OCRHit],
        pageRegions: [RedactionRegion],
        sensitiveTerms: [SensitiveTerm]
    ) -> PageOCRFinding {
        // Mirrors Layer 3's length filter (shared
        // `AhoCorasick.isSearchableTerm`). The memo's "filtered upstream ≥4"
        // cited spec text, not code — this helper receives raw terms.
        let validTerms = sensitiveTerms.filter { AhoCorasick.isSearchableTerm($0.text) }

        var sawTextInRegion = false
        var sawFillArtifactInRegion = false
        var sawSensitiveTermOutsideRegions = false
        var sawTextOutsideRegions = false

        for hit in hits {
            // Intersect WORD-level boxes when obtainable so a line
            // observation spanning a filled region (e.g. "John █████ Doe") does
            // not false-intersect on the survivors; fall back to the line box.
            // Part A: `boxFill` is index-parallel to these boxes (empty ⇒ unknown).
            let boxes = inRegionCandidateBoxes(of: hit)
            let samples = hit.boxFill

            var hitHasReadableInRegionBox = false
            var hitHasFillArtifactInRegionBox = false
            var hitHasOutOfRegionBox = false

            for (index, box) in boxes.enumerated() {
                // One word box over the bar pulls the hit in — the shared
                // predicate (`boxLiesInRegion`) requires MEANINGFUL
                // containment plus the polygon test.
                let inRegion = boxLiesInRegion(box, of: pageRegions)
                if inRegion {
                    // Part A: distinguish a fill artifact (Vision read a token off
                    // the SOLID bar — full-RGB fill-consistent on its in-region portion) from
                    // readable in-region ink. A fill-consistent box is DEMOTED (it
                    // raises only the fill-artifact signal below, which can never be
                    // a clean PASS), never silenced. Unknown sample (empty boxFill)
                    // ⇒ treat as readable — exactly today's behaviour.
                    let fillConsistent = index < samples.count && isFillConsistent(samples[index])
                    if fillConsistent {
                        hitHasFillArtifactInRegionBox = true
                    } else {
                        hitHasReadableInRegionBox = true
                    }
                } else {
                    // The hit's own (un-redacted) content, or the out-of-rect strokes
                    // of a straddle hit. Evaluated per box, so a demoted in-region
                    // box never short-circuits the hit and masks a sibling box that
                    // is genuinely outside every region (demote-never-silence).
                    sawTextOutsideRegions = true
                    hitHasOutOfRegionBox = true
                }
            }

            // A hit with readable strokes outside every region whose text matches
            // a sensitive term (same confidence gate and term filter as the
            // in-region FAIL above): the term the user redacted is still readable
            // somewhere on the page. `pageBucket(for:effectiveMode:)` maps the
            // signal to its own bucket on both page modes and the fold reports
            // ATTENTION; `outsideRegionTermTexts` re-walks the same geometry for
            // the term texts the results row names.
            if hitHasOutOfRegionBox,
               hit.confidence >= sensitiveTermFailConfidenceThreshold,
               let text = hit.text,
               validTerms.contains(where: { containsTerm(text, $0) }) {
                sawSensitiveTermOutsideRegions = true
            }

            if hitHasReadableInRegionBox {
                sawTextInRegion = true
                // FAIL only when a known sensitive term is readable inside the
                // region AND the hit clears the FAIL confidence gate. A
                // purely fill-consistent hit never reaches here, so a token
                // hallucinated off the bar that happens to match a term cannot FAIL
                // — there is no readable ink to leak.
                if hit.confidence >= sensitiveTermFailConfidenceThreshold,
                   let text = hit.text,
                   validTerms.contains(where: { containsTerm(text, $0) }) {
                    return .sensitiveTermInRegion   // fail outranks every other case
                }
            } else if hitHasFillArtifactInRegionBox {
                sawFillArtifactInRegion = true
            }
        }

        if sawTextInRegion { return .textInRegion }
        if sawFillArtifactInRegion { return .fillArtifactInRegion }
        if sawSensitiveTermOutsideRegions { return .sensitiveTermOutsideRegions }
        if sawTextOutsideRegions { return .textOutsideRegionsOnly }
        return .none
    }

    /// The one in-region predicate for a Layer-2 OCR box: MEANINGFUL
    /// containment — at least `inRegionCoverageThreshold` of the box's own
    /// area inside a region's `normalizedRect` — never an any-overlap edge
    /// touch. A still-visible word whose box clips a mid-line region's edge
    /// by a sliver is not in-region; a box substantially inside (a paint
    /// miss) still is. A polygon region's `normalizedRect` is only its
    /// bounding box — text the user deliberately preserved inside
    /// bbox-minus-polygon (an L-shape's notch) is NOT redacted content — so
    /// the box must also intersect the polygon itself (same normalized
    /// space; shared geometry with the character filter and Layer 6).
    /// Rect-only regions (`vertices == nil` or < 3) take the rect-coverage
    /// path alone. Shared by `classifyPageOCR` and `outsideRegionTermTexts`
    /// so the verdict and the term texts read the SAME geometry.
    static func boxLiesInRegion(_ box: CGRect, of pageRegions: [RedactionRegion]) -> Bool {
        pageRegions.contains { region in
            guard coverageFraction(of: box, inside: region.normalizedRect)
                    >= inRegionCoverageThreshold else { return false }
            guard let vertices = region.vertices, vertices.count >= 3 else { return true }
            return rectIntersectsPolygon(box, vertices: vertices)
        }
    }

    /// Display-only companion to `classifyPageOCR` for a page it classified
    /// `.sensitiveTermOutsideRegions`: the `SensitiveTerm.text` values
    /// contained by a hit with readable strokes outside every region, under
    /// the SAME per-box geometry (`boxLiesInRegion`), confidence gate and
    /// term filter the classifier applied. Insertion-ordered by first
    /// match, deduplicated; empty when nothing matches. Never feeds a
    /// verdict — the fold threads it to `LayerResult.reviewTermTexts` so
    /// the results row can name the text (the status message itself stays
    /// content-free).
    static func outsideRegionTermTexts(
        hits: [OCRHit],
        pageRegions: [RedactionRegion],
        sensitiveTerms: [SensitiveTerm]
    ) -> [String] {
        let validTerms = sensitiveTerms.filter { AhoCorasick.isSearchableTerm($0.text) }
        var seen = Set<String>()
        var texts: [String] = []
        for hit in hits {
            guard hit.confidence >= sensitiveTermFailConfidenceThreshold,
                  let text = hit.text else { continue }
            let boxes = inRegionCandidateBoxes(of: hit)
            guard boxes.contains(where: { !boxLiesInRegion($0, of: pageRegions) }) else { continue }
            for term in validTerms where containsTerm(text, term) && seen.insert(term.text).inserted {
                texts.append(term.text)
            }
        }
        return texts
    }

    /// Case-insensitive term containment pinned to en_US_POSIX, over both
    /// strings in the search path's normalized form (`TextNormalizer.normalize`
    /// — ligature expansion + NFKC), so a compatibility form of a term that
    /// the search can locate (a fullwidth spelling, a ligature glyph read
    /// off a raster) is never invisible to the text-space checks. Foundation's
    /// case-insensitive search folds the Latin ligatures on its own (Unicode
    /// full case folding); the explicit normalization covers the rest of the
    /// compatibility family and keeps this check aligned with the search
    /// path rather than with the folding table. Replaces
    /// `localizedCaseInsensitiveContains`, whose fold follows the device
    /// locale — under Turkish casing rules a dotless-I term can silently
    /// fail to match. Beyond that, case-only by design: diacritic-insensitivity
    /// would false-match distinct names, and NFKC keeps diacritics.
    static func containsTermCaseInsensitive(_ text: String, _ term: String) -> Bool {
        TextNormalizer.normalize(text).range(
            of: TextNormalizer.normalize(term), options: .caseInsensitive,
            locale: Locale(identifier: "en_US_POSIX")) != nil
    }

    /// Term containment with the model's boundary discipline — the
    /// String-space mirror of `SensitiveTermAutomaton.tokenFilteredMatches`'
    /// byte rule: a boundary-required match counts only when the characters
    /// adjacent to it are non-alphanumeric ASCII or absent (whitespace,
    /// punctuation, text edges, and non-ASCII characters all bound a token).
    /// Substring terms keep `containsTermCaseInsensitive` semantics.
    static func containsTerm(_ text: String, _ term: SensitiveTerm) -> Bool {
        guard term.requiresTokenBoundary else {
            return containsTermCaseInsensitive(text, term.text)
        }
        // The same normalization as the substring check above, applied
        // before the walk so the adjacency test reads the normalized text.
        let text = TextNormalizer.normalize(text)
        let termText = TextNormalizer.normalize(term.text)
        func embedsToken(_ character: Character) -> Bool {
            guard character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first, scalar.isASCII
            else { return false }
            return (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
        }
        var searchRange = text.startIndex..<text.endIndex
        while let match = text.range(
            of: termText, options: .caseInsensitive, range: searchRange,
            locale: Locale(identifier: "en_US_POSIX")) {
            let boundedBefore = match.lowerBound == text.startIndex
                || !embedsToken(text[text.index(before: match.lowerBound)])
            let boundedAfter = match.upperBound == text.endIndex
                || !embedsToken(text[match.upperBound])
            if boundedBefore && boundedAfter { return true }
            searchRange = match.upperBound..<text.endIndex
        }
        return false
    }

    /// Fraction of `box` that lies inside `region` (both in identity space, 0–1
    /// bottom-left). Returns 0 when the rectangles are disjoint or `box` is
    /// degenerate (zero area). Used by `classifyPageOCR` to require meaningful
    /// containment instead of an any-overlap edge touch (see
    /// `inRegionCoverageThreshold`). `static` so the coverage math has a direct
    /// unit test.
    static func coverageFraction(of box: CGRect, inside region: CGRect) -> CGFloat {
        let boxArea = box.width * box.height
        guard boxArea > 0 else { return 0 }
        let overlap = box.intersection(region)
        guard !overlap.isNull else { return 0 }
        return (overlap.width * overlap.height) / boxArea
    }

    /// Extract ALL embedded JPEG/JPEG2000 images from a PDF page's XObject
    /// streams. Returns every image, not just the first —
    /// a page can carry multiple image XObjects and each must be OCR-checked.
    ///
    /// Each image decodes via `CGImageSourceCreateThumbnailAtIndex`
    /// bounded by the existing `ocrMaxPixelDimension` cap, so a pathological
    /// embedded image cannot force an unbounded full-size transient decode
    /// (the prior `CGImageSourceCreateImageAtIndex` deferred the full-size
    /// decode to `downsampleForOCR`'s `ctx.draw`). Vision-facing quality is
    /// unaffected: the check reads text, not pixel fidelity, and normalized
    /// observation coordinates are scale-invariant (same argument as
    /// `downsampleForOCR`; the detection path applies the same 4096-px
    /// policy). `failedDecodeCount` counts JPEG/JPEG2000 streams whose decode
    /// produced no image (corrupt or undecodable data) — the caller buckets
    /// such a page `.unchecked`, because a decode failure must never read as
    /// "checked, found nothing". The `page.thumbnail` fallback path in
    /// `runLayer2OCR` is already size-bounded by the page box and is
    /// unchanged. `static` so the multi-image guard test can call it directly
    /// (mirrors the classifyPageOCR / layer2RegionSnapshot testing seam).
    static func extractPageImages(
        from cgPage: CGPDFPage
    ) -> (images: [CGImage], failedDecodeCount: Int) {
        guard let dict = cgPage.dictionary else { return ([], 0) }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources),
              let res = resources else { return ([], 0) }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "XObject", &xobjects),
              let xobj = xobjects else { return ([], 0) }

        var images: [CGImage] = []
        var failedDecodeCount = 0
        CGPDFDictionaryApplyBlock(xobj, { _, value, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream),
                  let s = stream else { return true }

            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(s, &format) else { return true }

            if format == .jpegEncoded || format == .JPEG2000 {
                // kCGImageSourceCreateThumbnailFromImageAlways: decode from
                // the full image (never a low-res embedded EXIF thumbnail);
                // max-pixel-size makes that decode capped, not full-size.
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: ocrMaxPixelDimension,
                ]
                if let source = CGImageSourceCreateWithData(data, nil),
                   let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    images.append(image)  // was `return false` (first only)
                } else {
                    failedDecodeCount += 1  // page must not read as checked
                }
            }
            return true  // keep iterating across all images
        }, nil)

        return (images, failedDecodeCount)
    }

    /// Downsample a decoded page image so its largest dimension is at
    /// most `ocrMaxPixelDimension` before Vision OCR. The Layer-2 check looks for
    /// readable leaked text, not pixel fidelity. Images already
    /// within the cap are returned unchanged. A context-construction or render
    /// failure falls back to the original image — a larger image still OCRs
    /// correctly, only slower, so this is a best-effort speed step, never a
    /// correctness gate. `static` so a guard test can pin the cap directly
    /// (mirrors the extractPageImages / classifyPageOCR testing seam).
    static func downsampleForOCR(_ image: CGImage) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > ocrMaxPixelDimension else { return image }
        let scale = CGFloat(ocrMaxPixelDimension) / CGFloat(longest)
        let newW = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let newH = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let ctx = createBitmapContext(width: newW, height: newH) else { return image }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }

    /// True when an image's pixel aspect ratio matches the requested page aspect
    /// within tolerance — i.e. a thumbnail render is unpadded. A
    /// padded (letterboxed) thumbnail scales/shifts Vision-normalized
    /// coordinates off page-normalized space, so its observations must be
    /// treated conservatively rather than identity-mapped.
    static func aspectMatches(_ imageSize: CGSize, _ pageSize: CGSize) -> Bool {
        guard imageSize.width > 0, imageSize.height > 0,
              pageSize.width > 0, pageSize.height > 0 else { return false }
        let imageAspect = imageSize.width / imageSize.height
        let pageAspect = pageSize.width / pageSize.height
        return abs(imageAspect - pageAspect) / pageAspect <= 0.02
    }

    /// PDF token delimiters + whitespace (ISO 32000 §7.2.2–§7.2.3). A structural
    /// match whose following byte is one of these is a complete PDF token.
    static let pdfDelimiters: Set<UInt8> = [
        0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20,   // whitespace: NUL TAB LF FF CR SP
        0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D,   // ( ) < > [ ]
        0x7B, 0x7D, 0x2F, 0x25,               // { } / %
    ]

    /// Raw (still-encoded) bytes of every JPEG XObject stream on a page. These
    /// carry the APP1/EXIF segments that PDFKit's page.string and the structural
    /// raw-byte pass do not surface (the bytes live inside the image stream).
    static func extractRawJPEGStreams(from cgPage: CGPDFPage) -> [Data] {
        guard let dict = cgPage.dictionary else { return [] }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources),
              let res = resources else { return [] }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "XObject", &xobjects),
              let xobj = xobjects else { return [] }
        var streams: [Data] = []
        CGPDFDictionaryApplyBlock(xobj, { _, value, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream),
                  let s = stream else { return true }
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(s, &format) else { return true }
            if format == .jpegEncoded { streams.append(data as Data) }  // EXIF is JPEG-only
            return true
        }, nil)
        return streams
    }

    /// Scan a raw JPEG byte stream's APP1/EXIF segment(s) for any automaton
    /// match. Each `FF E1` segment is length-prefixed (2 big-endian bytes,
    /// INCLUDING the length field); a segment beginning with the `Exif\0\0`
    /// magic has its payload searched. Read-only and WARN-only — tolerant of
    /// multi-APP1 and truncated segments (worst case: a missed warn).
    static func jpegEXIFContainsTerm(_ jpeg: Data, automaton: AhoCorasick) -> Bool {
        let bytes = [UInt8](jpeg)
        let exifMagic: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]  // "Exif\0\0"
        var i = 0
        while i + 4 <= bytes.count {
            guard bytes[i] == 0xFF, bytes[i + 1] == 0xE1 else { i += 1; continue }
            let segLen = (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])  // includes the 2 length bytes
            let payloadStart = i + 4
            let payloadEnd = min(i + 2 + segLen, bytes.count)          // clamp: truncated-safe
            guard payloadStart < payloadEnd else { i += 2; continue }
            let payload = bytes[payloadStart..<payloadEnd]
            if payload.starts(with: exifMagic),
               !automaton.search(Data(payload)).isEmpty {
                return true
            }
            i = payloadEnd
        }
        return false
    }
}
