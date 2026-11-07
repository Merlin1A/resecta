import CoreGraphics
import Foundation
import PDFKit
import Vision

// The hidden-word check's dispatcher: for each page of a Searchable export,
// the words left in its text layer, the print recognized on a fresh render of
// the SOURCE page, and the boxes, through `HiddenWordInkCheck.verdict`.
//
// The print must come from the source: the export paints its fill over every
// box, so a read of the output can clear a word but never place one under a
// box. The read is the check's own: its own render, one recognition pass at
// the verifier's frozen configuration (`OCRConfiguration.verificationLayer2`)
// on its own serial queue, and none of the search's ink-fit code. The source
// is the caller's copy of the original (`sourceDocument`); with none, or a
// locked one, the check could not verify. It never throws for an unsure
// page (a throw reads as a failure in `runLayer`); only a cancel throws.

extension VerificationEngine {

    /// The source read, made injectable for tests: the recognized words of
    /// page `index` of the source, or a thrown read error. Nil in
    /// production (the render and the recognition pass below). Task-local,
    /// so a test binds it for its own task tree only.
    @TaskLocal static var hiddenWordInkSourceRead: (@Sendable (Int) throws -> [HiddenWordInkWord])?

    /// The render resolution for the source read, capped so the longer side
    /// stays within Vision's useful size.
    static let hiddenWordInkDPI: CGFloat = 300
    static let hiddenWordInkMaxPixelDimension: CGFloat = 4096

    /// The approved strings of the check (row title in `VerificationLayer`).
    static func hiddenWordInkFailed(page: Int) -> String {
        "Page \(page): a box covers a word whose hidden copy is still in the text layer."
    }
    static func hiddenWordInkCouldNotCheck(page: Int) -> String {
        "Page \(page): the hidden text could not be matched to the printed words, so its boxes were not checked."
    }
    static func hiddenWordInkEdgeNote(page: Int) -> String {
        "Page \(page): a word beside a box was kept; its print only touches the box's edge."
    }
    static let hiddenWordInkPassed = "No hidden copy of a boxed word was found."
    static let hiddenWordInkNotApplicable = "No page keeps hidden text over a picture of the page."

    /// One page's outcome, before the fold.
    enum HiddenWordInkPage: Equatable {
        case verdict(HiddenWordInkVerdict)
        /// The check could not read this page or its source.
        case couldNotCheck
    }

    /// Run the check over every page of `doc`. Returns the status, its
    /// pages, the could-not-verify flag and the layer's own copy.
    func runHiddenWordInk(
        _ doc: PDFDocument,
        regions: [Int: [RedactionRegion]],
        sourceDocument: SendablePDFDocument?
    ) async throws -> (VerificationStatus, [Int]?, Bool, LayerCopy?) {
        try Task.checkCancellation()
        var outcomes: [(page: Int, outcome: HiddenWordInkPage)] = []
        let source = sourceDocument.flatMap { $0.document.isLocked ? nil : $0.document }
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            let outcome = try await hiddenWordInkPage(i, output: doc, regions: regions[i] ?? [], source: source)
            outcomes.append((i, outcome))
        }
        return Self.foldHiddenWordInk(outcomes)
    }

    /// One page: nothing to check (the export's own text, the boxes, the
    /// source's page facts), else the read and the verdict.
    private func hiddenWordInkPage(
        _ i: Int, output: PDFDocument, regions: [RedactionRegion], source: PDFDocument?
    ) async throws -> HiddenWordInkPage {
        guard let page = output.page(at: i) else {
            // A page that cannot be opened may hold text: unsure if boxed.
            return regions.isEmpty ? .verdict(HiddenWordInkVerdict(notApplicable: .noRegions)) : .couldNotCheck
        }
        let text = page.string ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .verdict(HiddenWordInkVerdict(notApplicable: .noText))
        }
        if regions.isEmpty { return .verdict(HiddenWordInkVerdict(notApplicable: .noRegions)) }
        guard let source, let sourcePage = source.page(at: i), let cgSource = sourcePage.pageRef else {
            return .couldNotCheck
        }
        let kind: HiddenWordInkPageKind = PageContentFacts.read(cgSource).isPlain ? .plain : .textOverImage
        if kind == .plain { return .verdict(HiddenWordInkVerdict(notApplicable: .plainSource)) }

        let visual = effectiveBounds(page.bounds(for: .cropBox), rotation: page.rotation).size
        let outputWords = Self.hiddenWordInkOutputWords(page)
        let sourceWords: [HiddenWordInkWord]
        if let read = Self.hiddenWordInkSourceRead {
            do { sourceWords = try read(i) } catch { return .couldNotCheck }  // LegalPhrases:safe (Swift keyword)
        } else {
            guard let read = try await Self.hiddenWordInkRead(sourcePage, cgPage: cgSource, pageIndex: i) else {
                return .couldNotCheck
            }
            sourceWords = read
        }
        try Task.checkCancellation()
        guard let outputWords else { return .couldNotCheck }
        return .verdict(HiddenWordInkCheck.pageVerdict(
            pageIndex: i, exportWords: outputWords, glyphs: Self.hiddenWordInkSourceGlyphs(sourcePage),
            sourceInk: sourceWords, regions: regions, pageSize: visual, kind: kind,
            axis: HiddenWordInkAxis(rotation: sourcePage.rotation)))
    }

    /// Fold the pages: any flagged word → FAIL; else any page not inspected or
    /// not read → WARN that could not verify; else any edge note → INFO;
    /// else any page checked → PASS; else NOT APPLICABLE. Each message names
    /// the first such page; the references list every one.
    static func foldHiddenWordInk(
        _ outcomes: [(page: Int, outcome: HiddenWordInkPage)]
    ) -> (VerificationStatus, [Int]?, Bool, LayerCopy?) {
        var failed: [Int] = [], unsure: [Int] = [], noted: [Int] = [], checked = false
        for (page, outcome) in outcomes {
            switch outcome {
            case .couldNotCheck:
                unsure.append(page)
            case .verdict(let v):
                if v.notApplicable != nil { continue }
                checked = true
                if !v.findings.isEmpty { failed.append(page) }
                if v.unplaceableNearBox { unsure.append(page) }
                if !v.edgeNotes.isEmpty { noted.append(page) }
            }
        }
        if let first = failed.first {
            return (.fail(hiddenWordInkFailed(page: first + 1)), failed, false, nil)
        }
        if let first = unsure.first {
            return (.warn(hiddenWordInkCouldNotCheck(page: first + 1)), unsure, true, nil)
        }
        if let first = noted.first {
            return (.info(hiddenWordInkEdgeNote(page: first + 1)), noted, false, nil)
        }
        if checked {
            return (.pass, nil, false, LayerCopy(short: hiddenWordInkPassed, detail: ""))
        }
        return (.notApplicable(hiddenWordInkNotApplicable), nil, false, nil)
    }

    /// The source page's hidden characters, in `page.string` order: each
    /// composed character that is not whitespace, boxed by its own selection
    /// in the frame the regions use, with its line. A character PDFKit gives
    /// no box is left out (the writer cannot have drawn it either).
    static func hiddenWordInkSourceGlyphs(_ page: PDFPage) -> [HiddenWordInkGlyph] {
        let text = (page.string ?? "") as NSString
        let searcher = DocumentSearcher()
        var glyphs: [HiddenWordInkGlyph] = []
        var line = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { _, lineRange, _, _ in
            text.enumerateSubstrings(in: lineRange, options: .byComposedCharacterSequences) { sub, range, _, _ in
                guard let sub, let char = sub.first, !char.isWhitespace,
                      let selection = page.selection(for: range),
                      let rect = searcher.normalizedRect(for: selection, page: page) else { return }
                glyphs.append(HiddenWordInkGlyph(char: char, rect: rect, line: line))
            }
            line += 1
        }
        return glyphs
    }

    // MARK: - The export's words

    /// The words of the export's text layer: `page.string` split into lines
    /// and words, each word boxed by its own selection in the frame the
    /// regions use. Nil when the page's text cannot be boxed at all.
    static func hiddenWordInkOutputWords(_ page: PDFPage) -> [HiddenWordInkWord]? {
        let text = (page.string ?? "") as NSString
        var words: [HiddenWordInkWord] = []
        var line = 0
        var unboxed = false
        let searcher = DocumentSearcher()
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { _, lineRange, _, _ in
            var start: Int?
            func close(_ end: Int) {
                guard let s = start else { return }
                start = nil
                let range = NSRange(location: s, length: end - s)
                guard let selection = page.selection(for: range),
                      let rect = searcher.normalizedRect(for: selection, page: page) else {
                    unboxed = true
                    return
                }
                words.append(HiddenWordInkWord(key: text.substring(with: range), rect: rect, line: line))
            }
            for k in lineRange.location..<(lineRange.location + lineRange.length) {
                let unit = text.character(at: k)
                let isSpace = unit < 0xD800 && CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(unit)!)
                if isSpace { close(k) } else if start == nil { start = k }
            }
            close(lineRange.location + lineRange.length)
            line += 1
        }
        // A word with no box is text whose place is unknown; the predicate
        // reads it as unplaceable through an empty rect.
        if unboxed { words.append(HiddenWordInkWord(key: "", rect: .null, line: -1)) }
        return words
    }

    // MARK: - The source read

    /// The check's own Vision queue: one perform at a time, off the
    /// cooperative pool (Layer 2's reasoning; a queue of its own, so the two
    /// checks share no code path).
    private static let hiddenWordInkVisionQueue = DispatchQueue(
        label: "com.resecta.RedactionEngine.verification.hidden-word-vision")

    private struct HiddenWordInkImageBox: @unchecked Sendable { let image: CGImage }

    /// The source page's crop box drawn by CoreGraphics on white at `dpi`,
    /// unrotated (its own page space, crop origin at the corner), with font
    /// smoothing off. Nil when no bitmap can be made.
    private static func hiddenWordInkRender(_ cgPage: CGPDFPage, size: CGSize, dpi: CGFloat) -> CGImage? {
        let scale = dpi / 72
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard width > 0, height > 0, let ctx = createBitmapContext(width: width, height: height) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setShouldSmoothFonts(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setAllowsFontSubpixelPositioning(false)
        ctx.scaleBy(x: scale, y: scale)
        let crop = cgPage.getBoxRect(.cropBox)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        ctx.addRect(crop)
        ctx.clip()
        ctx.drawPDFPage(cgPage)
        return ctx.makeImage()
    }

    /// A box normalized in the unrotated crop frame (`raw` size), turned
    /// into the normalized visual frame of a page whose /Rotate is `turn`:
    /// the same quarter-turn map the regions' frame is built with.
    static func hiddenWordInkTurn(_ r: CGRect, raw: CGSize, turn: Int) -> CGRect {
        let w = raw.width, h = raw.height
        let b = CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h)
        let v: CGRect
        let size: CGSize
        switch turn {
        case 90:
            v = CGRect(x: b.minY, y: w - b.maxX, width: b.height, height: b.width); size = CGSize(width: h, height: w)
        case 180:
            v = CGRect(x: w - b.maxX, y: h - b.maxY, width: b.width, height: b.height); size = raw
        case 270:
            v = CGRect(x: h - b.maxY, y: b.minX, width: b.height, height: b.width); size = CGSize(width: h, height: w)
        default:
            v = b; size = raw
        }
        return CGRect(x: v.minX / size.width, y: v.minY / size.height,
                      width: v.width / size.width, height: v.height / size.height)
    }

    /// A fresh render of the source page (no fills), one recognition pass,
    /// and its words: each recognized line's words with their boxes, and
    /// each line's own box as print with no key. Nil when the render or the
    /// read fails.
    static func hiddenWordInkRead(
        _ page: PDFPage, cgPage: CGPDFPage, pageIndex: Int
    ) async throws -> [HiddenWordInkWord]? {
        // Rendered in the page's unrotated crop frame, so text set upright in
        // the page's own space reads upright; each box is then turned into
        // the visual frame the regions use.
        let raw = page.bounds(for: .cropBox).size
        let longest = max(raw.width, raw.height)
        guard longest > 0 else { return nil }
        let dpi = min(hiddenWordInkDPI, hiddenWordInkMaxPixelDimension * 72 / longest)
        try Task.checkCancellation()
        guard let image = hiddenWordInkRender(cgPage, size: raw, dpi: dpi) else { return nil }
        let turn = ((page.rotation % 360) + 360) % 360
        let toVisual: @Sendable (CGRect) -> CGRect = { Self.hiddenWordInkTurn($0, raw: raw, turn: turn) }
        let boxed = HiddenWordInkImageBox(image: image)
        return await withCheckedContinuation { continuation in
            hiddenWordInkVisionQueue.async {
                let request = OCRConfiguration.verificationLayer2.makeRequest()
                let handler = VNImageRequestHandler(cgImage: boxed.image)
                do {  // LegalPhrases:safe (Swift keyword)
                    try handler.perform([request])
                } catch {  // LegalPhrases:safe (Swift keyword)
                    continuation.resume(returning: nil)
                    return
                }
                var words: [HiddenWordInkWord] = []
                for (line, observation) in (request.results ?? []).enumerated() {
                    words.append(HiddenWordInkWord(key: "", rect: toVisual(observation.boundingBox), line: line))
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let string = candidate.string
                    var index = string.startIndex
                    while index < string.endIndex {
                        guard !string[index].isWhitespace else { index = string.index(after: index); continue }
                        var end = index
                        while end < string.endIndex, !string[end].isWhitespace { end = string.index(after: end) }
                        if let box = try? candidate.boundingBox(for: index..<end) {
                            words.append(HiddenWordInkWord(key: String(string[index..<end]), rect: toVisual(box.boundingBox),
                                                           line: line))
                        }
                        index = end
                    }
                }
                continuation.resume(returning: words)
            }
        }
    }
}
