import CoreGraphics
import Foundation
import PDFKit
import RedactionEngine

// The manual-region text identity: at run entry the words the Searchable
// filter would touch under every `.manual` region on a page with a rich
// text layer are captured, line by line, and join the verifier's
// sensitive-term set, so a manual region is checked by the term layers
// exactly as a typed search or a detected region is. Regions on pages
// whose text layer is not rich cannot be captured and are counted for
// Layer 3's detail line; a whole-page region adds no term and is counted
// with them. Pure statics in
// the `sensitiveTerms(fromAppliedRegions:metadata:audit:)` shape, run off
// the MainActor; the value lives only in the run's
// inputs and is cleared with the output.

/// The verifier's term input for one run: the terms and the count of manual
/// regions that added no term — a whole-page region, or one whose page
/// carried no text layer to capture from. The second cause is kept apart,
/// app-side, as the page of each such region (`manualRegionPagesWithoutText`):
/// the results screen names those regions, which no check can read; the
/// engine receives the sum unchanged.
nonisolated struct SensitiveTermSet: Sendable, Equatable {
    let terms: [SensitiveTerm]
    let manualRegionsWithoutText: Int
    /// 0-based page of each manual region, short of a whole page, on a page
    /// whose text layer is not rich; one entry per region.
    let manualRegionPagesWithoutText: [Int]

    init(terms: [SensitiveTerm], manualRegionsWithoutText: Int = 0, manualRegionPagesWithoutText: [Int] = []) {
        self.terms = terms
        self.manualRegionsWithoutText = manualRegionsWithoutText
        self.manualRegionPagesWithoutText = manualRegionPagesWithoutText
    }

    static let empty = SensitiveTermSet(terms: [])
}

extension PipelineCoordinator {

    /// A region covering this fraction of the page or more is a whole-page
    /// redaction (the page-bar action's "Mark Whole Page" and any hand-drawn
    /// equivalent): it adds no term, and it is counted with the regions the
    /// string search could not capture, so Layer 3's note names it.
    nonisolated static let wholePageRegionArea: CGFloat = 0.95

    /// The run's term set: the applied-region terms plus the manual capture.
    ///
    /// Per `.manual` region (page by page, in region order): a whole-page
    /// region adds no term and is counted; on a page whose text layer is `.rich` the words
    /// the Searchable filter would touch (`ManualCapturePageWords.lines`)
    /// are captured — a region over exactly one word
    /// keeps that word as one bounded token (the user's intent); otherwise
    /// every captured LINE of two or more words joins as ONE substring
    /// term, the page text's verbatim span from its first word to its last
    /// ("123-45-6789" whole, never "123 45 6789"), and each captured word
    /// the admission rule keeps (`ManualTermStopWords.admits`: a digit, or
    /// four scalars or more outside the stop list) joins with token-boundary
    /// matching; lines never join across (no hyphen join). On any other
    /// page (`.sparse`, `.none`, or no entry) the region is counted, never
    /// captured — a header over a scanned body has no words under a rect on
    /// the body. Every other origin is untouched. Dedup with the applied
    /// terms keeps the least restrictive discipline any contributor asked
    /// for; the result is sorted by text like the applied set.
    nonisolated static func sensitiveTermSet(
        applied: [SensitiveTerm],
        manualRegions regions: [Int: [RedactionRegion]],
        in document: PDFDocument,
        textLayerStatus: [Int: TextLayerStatus],
        pageWords: (PDFPage) -> ManualCapturePageWords? = ManualCapturePageWords.init(page:)
    ) -> SensitiveTermSet {
        var requiresBoundaryByText: [String: Bool] = [:]
        func insert(_ text: String, requiresTokenBoundary: Bool) {
            requiresBoundaryByText[text] =
                (requiresBoundaryByText[text] ?? true) && requiresTokenBoundary
        }
        for term in applied {
            insert(term.text, requiresTokenBoundary: term.requiresTokenBoundary)
        }
        var withoutText = 0
        var pagesWithoutText: [Int] = []
        for (pageIndex, pageRegions) in regions.sorted(by: { $0.key < $1.key }) {
            let page = document.page(at: pageIndex)
            // The page's words are read once, on its first capturable region.
            var words: ManualCapturePageWords??
            // A `.manual` region carries no hidden glyphs' box (`textLayerRect`:
            // the canvas draw, the whole-page region and Duplicate all make
            // one without it), so its one rect is all the filter removes under.
            for region in pageRegions where region.source == .manual {
                let rect = region.normalizedRect.clampedToNormalized()
                if rect.width * rect.height >= Self.wholePageRegionArea {
                    withoutText += 1
                    continue
                }
                guard textLayerStatus[pageIndex] == .rich, let page else {
                    withoutText += 1
                    if textLayerStatus[pageIndex] != .rich { pagesWithoutText.append(pageIndex) }
                    continue
                }
                if words == nil { words = .some(pageWords(page)) }
                let lines = words??.lines(touching: rect) ?? []
                let captured = lines.flatMap(\.words)
                if captured.count == 1 {
                    insert(captured[0], requiresTokenBoundary: true)
                } else if captured.count > 1 {
                    for line in lines {
                        if line.words.count > 1 {
                            insert(line.text, requiresTokenBoundary: false)
                        }
                        for word in line.words where ManualTermStopWords.admits(word) {
                            insert(word, requiresTokenBoundary: true)
                        }
                    }
                }
            }
        }
        let terms = requiresBoundaryByText.map {
            SensitiveTerm(text: $0.key, requiresTokenBoundary: $0.value)
        }.sorted { $0.text < $1.text }
        return SensitiveTermSet(
            terms: terms, manualRegionsWithoutText: withoutText, manualRegionPagesWithoutText: pagesWithoutText)
    }

    /// The term set for a run starting now: the applied terms
    /// (`collectSensitiveTerms`) joined with the manual capture over the
    /// source document as it stands at entry. The regions and the per-page
    /// text-layer status are read on the MainActor; the capture — PDFKit's
    /// per-word selection over every manual region's page — runs detached.
    /// Without a document the applied terms
    /// are the whole set.
    func collectSensitiveTermSet() async -> SensitiveTermSet {
        let applied = collectSensitiveTerms()
        guard let document = documentState.sourceDocument else {
            return SensitiveTermSet(terms: applied)
        }
        let regions = redactionState.regions
        let status = documentState.textLayerStatus
        // nonisolated(unsafe): PDFDocument is not Sendable. Safe because the
        // detached closure only reads it (page lookups and per-word
        // selections), the run awaits the value before it touches the
        // document again, and the source is replaced only by an import,
        // which the pending run refuses (`DocumentState.canStartImport`).
        nonisolated(unsafe) let source = document
        return await Task.detached {
            Self.sensitiveTermSet(
                applied: applied, manualRegions: regions,
                in: source, textLayerStatus: status)
        }.value
    }
}

/// One captured line: consecutive words (reading order) on one baseline
/// band, with the page text's verbatim span from the first to the last.
nonisolated struct CapturedLine: Equatable, Sendable {
    let text: String
    let words: [String]
}

/// One page's text-layer words, read once for every manual region on the
/// page: the engine's word source (`EmbeddedTextSource`) with the words'
/// text and ranges, filtered per region either by the rule of the engine's
/// word-span primitive (`TextSpan.words(fullyInside:on:)`, which
/// reads the page again on every call) or by the Searchable filter's
/// removal rule (`lines(touching:)`).
nonisolated struct ManualCapturePageWords {

    /// `TextSpan.edgeTolerancePoints` (internal to the engine), in PDF
    /// points: a word touching the region's edge from inside by less than
    /// this is inside.
    static let edgeTolerancePoints: CGFloat = 0.5

    /// `CharacterFilter.safetyMarginPoints`: the removal's halo, in PDF
    /// points, on a line the region itself touches. Both values are pinned
    /// to the engine's by `ManualTermsMirrorParityTests`.
    static let removalHaloPoints: CGFloat = 3.0

    private let entries: [(text: String, box: CGRect, range: NSRange)]
    private let pageText: NSString
    private let displayedSize: CGSize

    init?(page: PDFPage) {
        guard let source = EmbeddedTextSource.make(from: page),
              let pageText = page.string else { return nil }
        let size = effectiveBounds(page.bounds(for: .cropBox), rotation: page.rotation).size
        guard size.width > 0, size.height > 0 else { return nil }
        let text = pageText as NSString
        entries = source.wordBounds.compactMap { word in
            NSMaxRange(word.range) <= text.length
                ? (text.substring(with: word.range), word.normalizedRect, word.range) : nil
        }
        self.pageText = text
        displayedSize = size
    }

    /// The lines the Searchable filter would touch under `rect`: a word is
    /// taken when its box meets the region (the filter's tier (a)), or meets
    /// the region's 3-pt halo while the region meets the word's own line
    /// band (tier (b)). Consecutive taken words whose boxes overlap vertically form one
    /// line; its text is the page text's verbatim span from the first word
    /// to the last when their ranges read in order on one line, else the
    /// words space-joined. Lines never join across.
    func lines(touching rect: CGRect) -> [CapturedLine] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        let halo = rect.insetBy(dx: -Self.removalHaloPoints / displayedSize.width,
                                dy: -Self.removalHaloPoints / displayedSize.height)
        var lines: [[(text: String, box: CGRect, range: NSRange)]] = []
        var previousIndex = -1
        for (index, word) in entries.enumerated() {
            let onBand = rect.minY < word.box.maxY && word.box.minY < rect.maxY
            guard word.box.intersects(rect) || (onBand && word.box.intersects(halo)) else { continue }
            if index == previousIndex + 1, let last = lines.last?.last,
               last.box.minY < word.box.maxY && word.box.minY < last.box.maxY {
                lines[lines.count - 1].append(word)
            } else {
                lines.append([word])
            }
            previousIndex = index
        }
        return lines.map { line in
            let words = line.map(\.text)
            guard let first = line.first, let last = line.last, line.count > 1,
                  first.range.location < last.range.location,
                  NSMaxRange(last.range) <= pageText.length else {
                return CapturedLine(text: words.joined(separator: " "), words: words)
            }
            let span = pageText.substring(
                with: NSRange(location: first.range.location,
                              length: NSMaxRange(last.range) - first.range.location))
            let joined = span.rangeOfCharacter(from: .newlines) == nil ? span : words.joined(separator: " ")
            return CapturedLine(text: joined, words: words)
        }
    }

    /// The words fully inside `rect` (page-normalized, displayed frame), in
    /// reading order.
    func words(fullyInside rect: CGRect) -> [String] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        let halo = rect.insetBy(dx: -Self.edgeTolerancePoints / displayedSize.width,
                                dy: -Self.edgeTolerancePoints / displayedSize.height)
        return entries.compactMap { word in
            guard halo.contains(word.box) else { return nil }
            return word.text
        }
    }
}
