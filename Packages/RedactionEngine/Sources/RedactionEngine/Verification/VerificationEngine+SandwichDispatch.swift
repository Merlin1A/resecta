import Foundation
import PDFKit
import Vision
import ImageIO
#if canImport(UIKit)
import UIKit  // PDFPage.thumbnail(of:for:) returns UIImage
#else
import AppKit  // macOS tooling destination: thumbnail returns NSImage
#endif

extension VerificationEngine {
    // MARK: - Per-page mode coverage (Layers 6–9)

    /// Layers 7–9 read only Searchable Redaction pages. When every page
    /// went through Secure Rasterization, no page kept a text layer and the
    /// check had nothing to check: NOT APPLICABLE, not a PASS.
    static let noTextLayerMessage =
        "No page kept a text layer — every page was rasterized, so this check had nothing to check."

    func noPageKeptATextLayer(_ perPageModes: [PipelineMode]) -> Bool {
        !perPageModes.isEmpty && !perPageModes.contains(.searchableRedaction)
    }

    /// The 0-based pages `perPageModes` does not describe — every index at
    /// or beyond `perPageModes.count` — or nil when the array covers the
    /// whole document. The Searchable-layer dispatchers (Layers 6–9) pick
    /// their pages through `perPageModes[i]`, so a short array silently
    /// leaves the tail of the document out of the check; each dispatcher
    /// reports that tail as a WARN on its otherwise-PASS exit instead of
    /// passing pages it never looked at. FAIL, `.skipped` and the layer's
    /// own WARNs keep precedence. The coordinator always supplies one mode
    /// per page, so on the product's own paths this returns nil.
    private func perPageModeCoverageGap(
        perPageModes: [PipelineMode], pageCount: Int
    ) -> [Int]? {
        guard perPageModes.count < pageCount else { return nil }
        return Array(perPageModes.count..<pageCount)
    }

    /// WARN copy for a per-page mode coverage gap — the mechanism only.
    private func perPageModeCoverageWarn(
        uncovered: [Int], pageCount: Int
    ) -> VerificationStatus {
        let covered = pageCount - uncovered.count
        let unchecked = uncovered.count == 1
            ? "1 page was" : "\(uncovered.count) pages were"
        return .warn(
            "Per-page mode data covered \(covered) of \(pageCount) "
            + "\(pageCount == 1 ? "page" : "pages") — \(unchecked) not checked"
        )
    }

    // MARK: - Layer 6: Spatial Verification

    /// Dispatch spatial verification across all Searchable Redaction pages.
    /// Collects all failing pages for tappable navigation chips.
    /// A page declared Secure Rasterization is not position-checked, but it
    /// is probed for a text layer: image-only output must carry none (the
    /// writer draws no text on such a page), so a text layer there FAILs
    /// the layer outright — a tampered or foreign output, never a skip.
    func runLayer6SpatialVerification(
        _ doc: PDFDocument,
        regions: [Int: [RedactionRegion]],
        perPageModes: [PipelineMode],
        verifier: SandwichVerification
    ) async throws -> (VerificationStatus, [Int]?, Bool) {
        // Entry-level cooperative cancellation.
        try Task.checkCancellation()
        var failingPages: [Int] = []
        var firstFailMessage: String?
        // Pages declared Secure Rasterization that still carry a text
        // layer. Image-only output must carry none, so this FAIL outranks
        // every other outcome of the layer.
        var secureDeclaredTextPages: [Int] = []
        // Per-page WARNs from the exclusion pass, in two classes: a
        // positional edge graze (the check ran; a note) and characters whose
        // position could not be measured (the check did not fully run).
        // They fold below FAIL and above the unreadable-page WARN; an
        // unmeasured page outranks every graze (its message names the first
        // such page; the grazed pages join the references), else the graze
        // sentence is composed ONCE over the grazed pages.
        var grazePages: [Int] = []
        var unmeasuredPages: [Int] = []
        var firstUnmeasuredMessage: String?
        // Eligible pages PDFKit cannot open surface as a WARN when the
        // layer would otherwise PASS — see runLayer1TextExtraction.
        var unreadablePages: [Int] = []

        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            // Pages beyond `perPageModes` are reported by the coverage arm
            // below. A page declared Secure Rasterization is probed for a
            // text layer — an image-only page must carry none — and is not
            // position-checked; the switch is exhaustive so a new mode
            // cannot be skipped silently.
            guard i < perPageModes.count else { continue }
            switch perPageModes[i] {
            case .secureRasterization:
                if let text = doc.page(at: i)?.string,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    secureDeclaredTextPages.append(i)
                }
                continue
            case .searchableRedaction:
                break
            }
            guard let page = doc.page(at: i) else {
                unreadablePages.append(i)
                continue
            }
            let pageRegions = regions[i] ?? []
            // Do NOT skip region-less pages. The empty pageRegions
            // flows through the maps below as regionShapes == [] into
            // verifySpatialExclusion, which (count-only guard) still runs the
            // origin-delta lattice — closing the glyph-position-tamper gap
            // on region-less searchable pages. Cost is bounded by the existing
            // 256-iteration cancellation cadence in the lattice walk.

            // Convert regions to output page coordinates (output pages
            // always have zero-origin bounds)
            let outputBounds = page.bounds(for: .cropBox)
            // The strip's own rects (`textRemovalRects`), so the exclusion
            // reads the hidden glyphs' box a region stripped as well.
            let rectsInPoints = pageRegions.flatMap(\.textRemovalRects).map {
                normalizedToPDFPageCoordinates($0, pageRect: outputBounds)
            }
            // `bounds` carries the un-expanded rect (the unconditional 0pt
            // floor + the band gate) and `expandedBounds` the filter's
            // safety-margin halo, so Layer 6 enforces the same two-tier
            // contract the character filter excludes by.
            let regionShapes: [RegionShape] = rectsInPoints.map { rect in
                RegionShape(
                    expandedBounds: rect.insetBy(dx: -safetyMarginPoints, dy: -safetyMarginPoints),
                    bounds: rect
                )
            }

            let outcome = try await verifier.spatialExclusionOutcome(
                outputPage: page,
                regionShapes: regionShapes,
                pageIndex: i
            )
            if case .fail(let msg) = outcome.status {
                failingPages.append(i)
                if firstFailMessage == nil { firstFailMessage = msg }
            } else if case .warn(let msg) = outcome.status {
                if outcome.grazed {
                    grazePages.append(i)
                } else {
                    unmeasuredPages.append(i)
                    if firstUnmeasuredMessage == nil { firstUnmeasuredMessage = msg }
                }
            }
        }
        // A text layer on a page written as image-only outranks every other
        // outcome: the page was declared to carry none.
        if !secureDeclaredTextPages.isEmpty {
            let list = secureDeclaredTextPages.map { String($0 + 1) }.joined(separator: ", ")
            return (.fail("A page written as image-only still carries a text layer on \(pagePhrase(secureDeclaredTextPages, list: list))"),
                    secureDeclaredTextPages, false)
        }
        if let msg = firstFailMessage {
            return (.fail(msg), failingPages, false)
        }
        // The exclusion pass's WARN outranks the unreadable-page WARN
        // (mirror of FAIL's masking above; the combined case is rare and the
        // exclusion message is the more actionable of the two). An
        // unmeasured position (the check did not fully run) outranks a graze
        // (a positional note; the check ran); the grazed pages ride along
        // as references.
        if let msg = firstUnmeasuredMessage {
            return (.warn(msg), (unmeasuredPages + grazePages).sorted(), true)
        }
        if !grazePages.isEmpty {
            return (SandwichVerification.grazeWarning(pages: grazePages), grazePages, false)
        }
        if !unreadablePages.isEmpty {
            return (unreadablePagesWarn(unreadablePages), unreadablePages, true)
        }
        // Pages beyond `perPageModes` were never selected above — report
        // them rather than pass them (see perPageModeCoverageGap).
        if let uncovered = perPageModeCoverageGap(
            perPageModes: perPageModes, pageCount: doc.pageCount
        ) {
            return (perPageModeCoverageWarn(
                uncovered: uncovered, pageCount: doc.pageCount), uncovered, true)
        }
        return (.pass, nil, false)
    }

    // MARK: - Layer 7: Character Count Cross-Check

    /// Dispatch character count verification across all Searchable Redaction pages.
    /// Collects every failing page, else every warned page, for the chips.
    func runLayer7CharacterCount(
        _ doc: PDFDocument,
        filterDigests: [PageFilterDigest?],
        perPageModes: [PipelineMode],
        verifier: SandwichVerification
    ) async throws -> (VerificationStatus, [Int]?, Bool) {
        // Entry-level cooperative cancellation.
        try Task.checkCancellation()
        var outcomes = PerPageOutcomes()
        // Track how many pages this
        // digest-consuming layer was eligible to cross-check vs how many it
        // actually checked, so a layer that ran no comparisons reports the
        // truth (.skipped) instead of a silent .pass.
        var eligible = 0
        var checked = 0

        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard i < perPageModes.count, perPageModes[i] == .searchableRedaction else {
                continue
            }
            eligible += 1
            guard i < filterDigests.count, let digest = filterDigests[i] else {
                continue
            }
            guard let page = doc.page(at: i) else { continue }

            checked += 1
            let result = try await verifier.verifyCharacterCount(
                outputPage: page, digest: digest
            )
            outcomes.record(result, page: i)
        }
        if let failure = outcomes.failure { return failure }
        // Eligible-but-unchecked → honest .skipped (the verify-only
        // resume path rebuilds all-nil digests). Partial coverage → .warn
        // (defensive; unreachable today since digests are all-present or
        // all-nil). eligible == 0 when `perPageModes` covers the document
        // reads NOT APPLICABLE on the exit below — every page is per-page
        // Secure Rasterization; promoting it to a warning would flag valid
        // docs (the false-positive trap one layer up). Pages beyond `perPageModes`
        // never counted as eligible, so they are reported last, on the
        // otherwise-PASS exit (see perPageModeCoverageGap).
        if eligible > 0 && checked == 0 {
            return (.skipped, nil, false)
        }
        if checked < eligible {
            return (.warn("Cross-checked \(checked) of \(eligible) \(eligible == 1 ? "page" : "pages") — remaining pages lacked rasterization data"), nil, true)
        }
        if let uncovered = perPageModeCoverageGap(
            perPageModes: perPageModes, pageCount: doc.pageCount
        ) {
            return (perPageModeCoverageWarn(
                uncovered: uncovered, pageCount: doc.pageCount), uncovered, true)
        }
        // The verifier's per-page count-excess warnings: a note (the check
        // ran), ranked below the could-not-verify warnings above.
        if let warning = outcomes.warning(couldNotVerify: false) { return warning }
        if noPageKeptATextLayer(perPageModes) {
            return (.notApplicable(Self.noTextLayerMessage), nil, false)
        }
        return (.pass, nil, false)
    }

    // MARK: - Layer 8: Font Verification

    /// Dispatch font verification across all Searchable Redaction pages.
    /// Collects every failing page, else every warned page, for the chips.
    func runLayer8FontVerification(
        _ doc: PDFDocument,
        perPageModes: [PipelineMode],
        verifier: SandwichVerification
    ) async throws -> (VerificationStatus, [Int]?, Bool) {
        // Entry-level cooperative cancellation.
        try Task.checkCancellation()
        var outcomes = PerPageOutcomes()
        // See runLayer1TextExtraction — unreadable eligible pages WARN
        // on the otherwise-PASS path.
        var unreadablePages: [Int] = []

        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard i < perPageModes.count, perPageModes[i] == .searchableRedaction else {
                continue
            }
            guard let page = doc.page(at: i) else {
                unreadablePages.append(i)
                continue
            }

            let result = try await verifier.verifyFontsAreMonospace(
                outputPage: page, pageIndex: i)
            outcomes.record(result, page: i)
        }
        if let failure = outcomes.failure { return failure }
        if !unreadablePages.isEmpty {
            return (unreadablePagesWarn(unreadablePages), unreadablePages, true)
        }
        // Pages beyond `perPageModes` were never selected above — report
        // them rather than pass them (see perPageModeCoverageGap).
        if let uncovered = perPageModeCoverageGap(
            perPageModes: perPageModes, pageCount: doc.pageCount
        ) {
            return (perPageModeCoverageWarn(
                uncovered: uncovered, pageCount: doc.pageCount), uncovered, true)
        }
        // The verifier's per-page warnings — a font it could not inspect,
        // a page with no page-level resources: the check did not run there.
        if let warning = outcomes.warning(couldNotVerify: true) { return warning }
        if noPageKeptATextLayer(perPageModes) {
            return (.notApplicable(Self.noTextLayerMessage), nil, false)
        }
        return (.pass, nil, false)
    }

    // MARK: - Layer 9: Character Lineage

    /// Dispatch character-lineage verification across all Searchable Redaction
    /// pages. Re-computes the SHA-256 over output composed-character iteration
    /// and reports mismatch against `PageFilterDigest.lineageHash`. Reorderings,
    /// insertions, deletions, and replacements of non-zero-bounds composed
    /// characters between filter and final PDF flip the hash. Zero-width
    /// insertions do NOT — both sides iterate non-zero-bounds composed
    /// characters only (pinned M4 residual; term-bearing injections are
    /// covered by Layers 3 and 10). See
    /// `SandwichVerification.verifyCharacterLineage`.
    func runLayer9CharacterLineage(
        _ doc: PDFDocument,
        filterDigests: [PageFilterDigest?],
        perPageModes: [PipelineMode],
        verifier: SandwichVerification
    ) async throws -> (VerificationStatus, [Int]?, Bool) {
        // Entry-level cooperative cancellation +
        // a per-page check, matching every other layer dispatcher; the
        // composed-character walk inside the verifier carries the banded
        // 256-cadence checks. `runLayer` converts the CancellationError to
        // `.skipped` exactly as for Layers 1–8.
        try Task.checkCancellation()
        var failingPages: [Int] = []
        var firstFailMessage: String?
        // See runLayer7CharacterCount — same
        // eligible/checked accounting so an unchecked digest-consuming layer
        // reports .skipped rather than a silent .pass.
        var eligible = 0
        var checked = 0

        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard i < perPageModes.count, perPageModes[i] == .searchableRedaction else {
                continue
            }
            eligible += 1
            guard i < filterDigests.count, let digest = filterDigests[i] else {
                continue
            }
            guard let page = doc.page(at: i) else { continue }

            checked += 1
            let result = try await verifier.verifyCharacterLineage(
                outputPage: page, digest: digest
            )
            if case .fail(let msg) = result {
                failingPages.append(i)
                if firstFailMessage == nil { firstFailMessage = msg }
            }
        }
        if let msg = firstFailMessage {
            return (.fail(msg), failingPages, false)
        }
        // Eligible-but-unchecked → .skipped; partial → .warn;
        // eligible == 0 reads NOT APPLICABLE (nothing to check); pages beyond
        // `perPageModes` are reported last. See Layer 7.
        if eligible > 0 && checked == 0 {
            return (.skipped, nil, false)
        }
        if checked < eligible {
            return (.warn("Cross-checked \(checked) of \(eligible) \(eligible == 1 ? "page" : "pages") — remaining pages lacked rasterization data"), nil, true)
        }
        if let uncovered = perPageModeCoverageGap(
            perPageModes: perPageModes, pageCount: doc.pageCount
        ) {
            return (perPageModeCoverageWarn(
                uncovered: uncovered, pageCount: doc.pageCount), uncovered, true)
        }
        if noPageKeptATextLayer(perPageModes) {
            return (.notApplicable(Self.noTextLayerMessage), nil, false)
        }
        return (.pass, nil, false)
    }
}
