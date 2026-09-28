import CoreGraphics
import Foundation
import PDFKit
import RedactionEngine

// The manual-region text identity: at run entry the words fully inside
// every `.manual` region on a page with a rich text layer are captured
// through the engine's word-span primitive and join the verifier's
// sensitive-term set, so a manual region is checked by the term layers
// exactly as a typed search or a detected region is. Regions on pages
// whose text layer is not rich cannot be captured and are counted for
// Layer 3's detail line; whole-page regions are skipped. Pure statics in
// the `sensitiveTerms(fromAppliedRegions:metadata:audit:)` shape, run off
// the MainActor like `buildOCRSkipHint`; the value lives only in the run's
// inputs and is cleared with the output.

/// The verifier's term input for one run: the terms and the count of manual
/// regions whose page carried no text layer to capture from.
nonisolated struct SensitiveTermSet: Sendable, Equatable {
    let terms: [SensitiveTerm]
    let manualRegionsWithoutText: Int

    init(terms: [SensitiveTerm], manualRegionsWithoutText: Int = 0) {
        self.terms = terms
        self.manualRegionsWithoutText = manualRegionsWithoutText
    }

    static let empty = SensitiveTermSet(terms: [])
}

extension PipelineCoordinator {

    /// A region covering this fraction of the page or more is a whole-page
    /// redaction: it adds no term and is not counted (the page-bar action's
    /// "Redact Whole Page" and any hand-drawn equivalent).
    nonisolated static let wholePageRegionArea: CGFloat = 0.95

    /// The run's term set: the applied-region terms plus the manual capture.
    ///
    /// Per `.manual` region (page by page, in region order): a whole-page
    /// region is skipped; on a page whose text layer is `.rich` the words
    /// fully inside the region (its polygon honoured) are captured — a
    /// multi-word run joins as ONE substring term plus each token of three
    /// or more scalars with token-boundary matching (the single-token rule
    /// of `sensitiveTerms(fromAppliedRegions:metadata:audit:)`), a single
    /// word as that one bounded token; on any other page (`.sparse`,
    /// `.none`, or no entry) the region is counted, never captured — a
    /// header over a scanned body has no words under a rect on the body.
    /// Every other origin is untouched. Dedup with the applied terms keeps
    /// the least restrictive discipline any contributor asked for; the
    /// result is sorted by text like the applied set.
    nonisolated static func sensitiveTermSet(
        applied: [SensitiveTerm],
        manualRegions regions: [Int: [RedactionRegion]],
        in document: PDFDocument,
        textLayerStatus: [Int: TextLayerStatus]
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
        for (pageIndex, pageRegions) in regions.sorted(by: { $0.key < $1.key }) {
            let page = document.page(at: pageIndex)
            for region in pageRegions where region.source == .manual {
                let rect = region.normalizedRect.clampedToNormalized()
                if rect.width * rect.height >= Self.wholePageRegionArea { continue }
                guard textLayerStatus[pageIndex] == .rich, let page else {
                    withoutText += 1
                    continue
                }
                let words = TextSpan.words(
                    fullyInside: rect, polygon: region.vertices, on: page
                ).map(\.text)
                if words.count == 1 {
                    insert(words[0], requiresTokenBoundary: true)
                } else if words.count > 1 {
                    insert(words.joined(separator: " "), requiresTokenBoundary: false)
                    for word in words where word.unicodeScalars.count >= 3 {
                        insert(word, requiresTokenBoundary: true)
                    }
                }
            }
        }
        let terms = requiresBoundaryByText.map {
            SensitiveTerm(text: $0.key, requiresTokenBoundary: $0.value)
        }.sorted { $0.text < $1.text }
        return SensitiveTermSet(terms: terms, manualRegionsWithoutText: withoutText)
    }

    /// The term set for a run starting now: the applied terms
    /// (`collectSensitiveTerms`) joined with the manual capture over the
    /// source document as it stands at entry. The regions and the per-page
    /// text-layer status are read on the MainActor; the capture — PDFKit's
    /// per-word selection over every manual region's page — runs detached,
    /// the `buildOCRSkipHint` shape. Without a document the applied terms
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
