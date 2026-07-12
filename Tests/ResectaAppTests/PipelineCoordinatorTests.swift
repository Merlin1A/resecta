import Testing
import Foundation
import PDFKit
import CoreGraphics
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

@Suite("PipelineCoordinator.buildPDFPageData")
@MainActor
struct PipelineCoordinatorTests {

    // MARK: - Basic Behavior

    @Test("Returns empty array when no document loaded")
    func emptyForNoDocument() {
        let coord = makeCoordinator()
        let pages = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pages.isEmpty)
    }

    @Test("Returns page data for loaded document")
    func returnsPageDataForDocument() {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        let pages = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pages.count == 1)
    }

    @Test("Preserves page index in output")
    func preservesPageIndex() {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        let pages = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pages.first?.pageIndex == 0)
    }

    // MARK: - Region Filtering (K3.1, AD-4-1)

    @Test("Filters sub-threshold regions (width/height ≤ 0.001)")
    func filtersSubThresholdRegions() {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()

        let tiny = RedactionRegion(id: UUID(),
            normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0.0005, height: 0.0005),
            source: .manual)
        let normal = RedactionRegion(id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            source: .manual)
        coord.redactionState.regions[0] = [tiny, normal]

        let pages = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pages.first?.regions.count == 1)
        #expect(pages.first?.regions.first?.id == normal.id)
    }

    @Test("Empty regions for page with no stored regions (not nil)")
    func emptyRegionsNotNil() {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        // No regions stored for page 0
        let pages = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pages.first?.regions.isEmpty == true)
    }

    // MARK: - Per-Page Mode Selection

    @Test("Always secureRasterization when effectiveMode is secureRasterization")
    func alwaysSecureWhenEffectiveModeSecure() {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        coord.documentState.textLayerStatus[0] = .rich

        let pages = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pages.first?.pipelineMode == .secureRasterization)
        // PD-5: a secure-raster-mode run rasterizes by choice — no reason.
        #expect(pages.first?.fallbackReason == nil)
    }

    @Test("searchableRedaction only when effectiveMode=searchable AND textLayerStatus=rich")
    func searchableWhenRich() {
        let coord = makeCoordinator()
        // The gate now runs checkFallbackTriggers on
        // the page, so the fixture must carry real extractable text — a blank
        // page with a hand-stamped .rich status trips .noExtractableText and
        // (correctly) falls back to secure.
        coord.documentState.sourceDocument = makeRichTextPDFDocument(
            text: "The quick brown fox jumps over the lazy dog near the river bank."
        )
        coord.documentState.textLayerStatus[0] = .rich

        let pages = coord.buildPDFPageData(effectiveMode: .searchableRedaction)
        #expect(pages.first?.pipelineMode == .searchableRedaction)
        // PD-5: a page that keeps searchable mode carries no reason.
        #expect(pages.first?.fallbackReason == nil)
    }

    @Test("Falls back to secureRasterization when textLayerStatus is sparse")
    func fallbackWhenSparse() {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        coord.documentState.textLayerStatus[0] = .sparse

        let pages = coord.buildPDFPageData(effectiveMode: .searchableRedaction)
        #expect(pages.first?.pipelineMode == .secureRasterization)
        // PD-5: a sparse page in a Searchable-mode run is a per-page
        // fallback the report explains.
        #expect(pages.first?.fallbackReason == .noExtractableText)
    }

    @Test("Falls back to secureRasterization when no textLayerStatus entry")
    func fallbackWhenNoStatus() {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        // No textLayerStatus entry for page 0

        let pages = coord.buildPDFPageData(effectiveMode: .searchableRedaction)
        #expect(pages.first?.pipelineMode == .secureRasterization)
        #expect(pages.first?.fallbackReason == .noExtractableText)
    }

    // MARK: - Settings Integration

    @Test("Uses settings fill color")
    func usesFillColor() {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        coord.settingsState.fillColor = .white

        let pages = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pages.first?.fillColor == .white)
    }

    @Test("Uses settings export DPI")
    func usesExportDPI() {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        coord.settingsState.exportDPI = 200

        let pages = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pages.first?.targetDPI == 200)
    }

    // MARK: - Page Rotation

    @Test("Preserves page rotation in PDFPageData")
    func usesPageRotation() {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        let pages = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        // Standard PDF page has rotation 0
        #expect(pages.first?.rotation == 0)
    }

    // MARK: - M1: hasHiddenOCG plumbing

    @Test("Propagates documentState.sourceHasHiddenOCG to every page (M1)")
    func propagatesHiddenOCGFlag() {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeMultiPagePDFDocument(pages: 3)
        coord.documentState.sourceHasHiddenOCG = true

        let pages = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pages.count == 3)
        #expect(pages.allSatisfy { $0.hasHiddenOCG })
    }

    @Test("Defaults hasHiddenOCG to false on plain document (M1)")
    func defaultsHiddenOCGFalse() {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        // sourceHasHiddenOCG defaults to false
        let pages = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pages.first?.hasHiddenOCG == false)
    }

    // MARK: - Multi-Page Ordering

    @Test("Multi-page document preserves page order")
    func multiPagePreservesOrder() {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeMultiPagePDFDocument(pages: 3)
        let pages = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pages.count == 3)
        #expect(pages.map(\.pageIndex) == [0, 1, 2])
    }

    @Test("Regions only on page 1 leaves page 0 empty")
    func regionOnlyOnPage1() {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeMultiPagePDFDocument(pages: 2)
        let region = RedactionRegion(id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            source: .manual)
        coord.redactionState.regions[1] = [region]

        let pages = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pages[0].regions.isEmpty)
        #expect(pages[1].regions.count == 1)
    }

    @Test("Default fill color matches settings default")
    func fillColorDefault() {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        let pages = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pages.first?.fillColor == coord.settingsState.fillColor)
    }

    // MARK: - KI-5: Memory-warning DPI ceiling (L-18)

    @Test("Default dpiCap is 300")
    func defaultDPICap() {
        let coord = makeCoordinator()
        #expect(coord.dpiCap == 300, "dpiCap defaults to full-quality 300")
    }

    @Test("Memory warning lowers dpiCap to 150")
    func memoryWarningLowersDPICap() async throws {
        let coord = makeCoordinator()
        #expect(coord.dpiCap == 300, "initial dpiCap")

        // The observer Task is scheduled in init but won't register its
        // NotificationCenter subscription until the MainActor yields and
        // the `for await` loop reaches its first iteration. Give it time.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        // Async-sequence delivery: poll briefly for the observer to fire.
        for _ in 0..<50 {
            if coord.dpiCap == 150 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(coord.dpiCap == 150,
                "didReceiveMemoryWarningNotification should lower dpiCap to 150")
    }

    // MARK: - F-002 sibling — MainActor PDF parse move-off (Package F)

    /// The `runVerification` entry point used to call `PDFDocument(url:)`
    /// synchronously on the MainActor; per F-002 the parse moves into a
    /// `nonisolated static` helper invoked via `Task.detached`. The
    /// off-MainActor invariant is mostly compile-time-enforced (`nonisolated`),
    /// so the practical surface for this suite is "the helper exists,
    /// succeeds on a valid file, and throws the expected
    /// `PipelineError.verificationError(.engineCrash(layerIndex: 0))` on a
    /// missing or unreadable file." Matches the spec implication noted in
    /// `03-security-perf-audit.md §1.2.a`.
    @Test("loadOutputDocumentOffMainActor returns a wrapped document for a valid PDF URL")
    func loadOutputDocumentSucceeds() async throws {
        let url = try writeTempPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let wrapped = try await Task.detached {
            try PipelineCoordinator.loadOutputDocumentOffMainActor(url)
        }.value
        #expect(wrapped.document.pageCount == 1)
    }

    @Test("loadOutputDocumentOffMainActor throws verificationError on missing file")
    func loadOutputDocumentThrowsOnMissingFile() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ki4-pkg-f-missing-\(UUID().uuidString).pdf")
        await #expect(throws: PipelineError.self) {
            try await Task.detached {
                try PipelineCoordinator.loadOutputDocumentOffMainActor(url)
            }.value
        }
    }

    @Test("loadOutputDocumentOffMainActor maps parse failure to verificationError.engineCrash(0)")
    func loadOutputDocumentErrorShape() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ki4-pkg-f-bad-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        // Write a non-PDF blob so PDFDocument(url:) fails.
        try Data("not a pdf".utf8).write(to: url)
        do {
            _ = try await Task.detached {
                try PipelineCoordinator.loadOutputDocumentOffMainActor(url)
            }.value
            Issue.record("expected throw")
        } catch let error as PipelineError { // LegalPhrases:safe (Swift keyword)
            if case .verificationError(.engineCrash(let layer)) = error {
                #expect(layer == 0)
            } else {
                Issue.record("unexpected PipelineError case: \(error)")
            }
        }
    }

    // MARK: - Per-page mode gate (S1: D2 rotation stopgap + ENGINE §5A RTL wiring)

    @Test("Searchable mode, rich unrotated English page stays searchable")
    func searchableRichUnrotatedPageStaysSearchable() throws {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeRichTextPDFDocument(
            text: "The quick brown fox jumps over the lazy dog near the river bank."
        )
        coord.documentState.textLayerStatus[0] = .rich
        let pages = coord.buildPDFPageData(effectiveMode: .searchableRedaction)
        #expect(pages.first?.pipelineMode == .searchableRedaction)
    }

    @Test("CAT-353 (s15): rotated rich page now takes searchableRedaction",
          arguments: [90, 180, 270])
    func rotatedRichPageTakesSearchable(rotation: Int) throws {
        // s15 stopgap removal (D-34 / D-35): the former D2 stopgap forced
        // secureRasterization for rotated pages because PageRasterizer pixel
        // fill and CharacterFilter read normalizedRect in incompatible spaces
        // under /Rotate. The canonical coordinate contract is now complete —
        // extractCharacters applies T_rot — so a rotated rich page (no fallback
        // trigger) takes searchable mode. Leak-freedom across all four rotations
        // and both CropBox origins is proven by the D-35
        // RotatedPageCoordinateTests matrix.
        let coord = makeCoordinator()
        let doc = makeRichTextPDFDocument(
            text: "The quick brown fox jumps over the lazy dog near the river bank."
        )
        let page = try #require(doc.page(at: 0))
        page.rotation = rotation
        coord.documentState.sourceDocument = doc
        coord.documentState.textLayerStatus[0] = .rich

        let pages = coord.buildPDFPageData(effectiveMode: .searchableRedaction)
        #expect(pages.first?.pipelineMode == .searchableRedaction)
        #expect(pages.first?.rotation == rotation)
    }

    @Test("ENGINE §5A: RTL rich page falls back to secureRasterization")
    func rtlRichPageFallsBackToSecure() throws {
        // Arabic text trips TextLayerDetector.checkFallbackTriggers(.rtlText);
        // the gate must route the page to the visual path instead of trusting
        // PDFKit bounds (previously the trigger had zero production callers).
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeRichTextPDFDocument(
            text: "هذا مستند تجريبي باللغة العربية للتحقق من مسار التراجع"
        )
        coord.documentState.textLayerStatus[0] = .rich
        let pages = coord.buildPDFPageData(effectiveMode: .searchableRedaction)
        #expect(pages.first?.pipelineMode == .secureRasterization)
        // PD-5 / RC-5: the trigger's reason is recorded, not discarded.
        #expect(pages.first?.fallbackReason == .rtlText)
    }

    @Test("Secure mode stays secure regardless of rotation or text layer")
    func secureModeUnaffectedByGateInputs() throws {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeRichTextPDFDocument(
            text: "The quick brown fox jumps over the lazy dog near the river bank."
        )
        coord.documentState.textLayerStatus[0] = .rich
        let pages = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pages.first?.pipelineMode == .secureRasterization)
        #expect(pages.first?.fallbackReason == nil)
    }

    // MARK: - Helpers

    private func makeCoordinator() -> PipelineCoordinator {
        PipelineCoordinator(
            documentState: DocumentState(),
            redactionState: RedactionState(),
            settingsState: SettingsState()
        )
    }

    /// Create a minimal 1-page PDFDocument for testing.
    private func makeTestPDFDocument() -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            // Blank page
        }
        return PDFDocument(data: data)!
    }

    /// 1-page PDFDocument with a real extractable text layer (rich: ≥10 chars).
    private func makeRichTextPDFDocument(text: String) -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24),
                .foregroundColor: UIColor.black
            ]
            (text as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: attrs)
        }
        return PDFDocument(data: data)!
    }

    /// Write a minimal valid single-page PDF to a unique temp URL.
    /// Returns the URL; caller is responsible for cleanup.
    private func writeTempPDF() throws -> URL {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ki4-pkg-f-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }
}

// 01-FIX (Issue A, 2026-06-25): collectSensitiveTerms is scoped to the APPLIED
// redactions (its prior pass harvested every detection in detectionResults,
// including triage-deselected ones — which surfaced as false "Sensitive text
// in region" Layer-2 reports). These pin the scoping on the pure seam and
// through the instance method.
//
// PD-3 (SV-5) re-pin: single-token name matched text is INCLUDED with
// `requiresTokenBoundary` (the byte layers post-filter embedded hits), the
// search TERM contributes only for typed rows (where the query IS the
// sensitive text — detector/user-term rows carry a category label or
// "Custom" placeholder there), and matched text contributes for every region.
@Suite("PipelineCoordinator.collectSensitiveTerms scoping (01-FIX Issue A + PD-3)")
@MainActor
struct CollectSensitiveTermsScopingTests {

    private func seededRegion(_ source: RedactionRegion.Source) -> RedactionRegion {
        RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
            source: source)
    }

    /// Rationale carried by detector / user-term search rows (typed rows
    /// carry none) — the term-insert discriminator.
    private func detectorRationale(_ ruleID: String = "pii.name") -> MatchRationale {
        MatchRationale(
            ruleID: ruleID, signals: [],
            preThresholdScore: 0.9, finalScore: 0.9, appliedThreshold: 0.5)
    }

    /// text → requiresTokenBoundary, for assertion convenience.
    private func termTable(_ terms: [SensitiveTerm]) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: terms.map { ($0.text, $0.requiresTokenBoundary) })
    }

    @Test("Applied matched text included (single names boundary-flagged); deselected detection excluded")
    func appliedTermsScoping() {
        let coord = makeCoordinator()

        let multiName = seededRegion(.detectedPII(kind: .name))
        let singleName = seededRegion(.detectedPII(kind: .name))
        let account = seededRegion(.detectedPII(kind: .account))
        let search = seededRegion(.searchMatch(term: "Wrenfield"))

        coord.redactionState.regions = [0: [multiName, singleName, account, search]]
        coord.redactionState.regionMetadata = [
            multiName.id:  .mock(piiKind: .pii(.name),    matchedText: "Delia Hartwell"),
            singleName.id: .mock(piiKind: .pii(.name),    matchedText: "Hartwell"),
            account.id:    .mock(piiKind: .pii(.account), matchedText: "4100773265"),
            search.id:     .mock(piiKind: .searchMatch(term: "Wrenfield"), matchedText: "Wrenfield"),
        ]
        // A detection the user DESELECTED in triage: it lingers in
        // detectionResults but has no applied region → must not be a term.
        coord.redactionState.detectionResults = [
            0: [DetectionResult.mock(kind: .pii(.ssn), matchedText: "999-00-1234")]
        ]

        let terms = termTable(coord.collectSensitiveTerms())
        #expect(terms["Delia Hartwell"] == false)  // multi-word name: plain substring
        #expect(terms["4100773265"] == false)      // non-name single token: plain
        #expect(terms["Wrenfield"] == false)       // typed search term kept
        #expect(terms["Hartwell"] == true)         // single-word name: boundary-matched
        #expect(terms["999-00-1234"] == nil)       // deselected detection not hunted
    }

    @Test("Pure seam keeps a single-word name token with the boundary requirement")
    func pureSeamScoping() {
        let name = seededRegion(.detectedPII(kind: .name))
        let terms = PipelineCoordinator.sensitiveTerms(
            fromAppliedRegions: [0: [name]],
            metadata: [name.id: .mock(piiKind: .pii(.name), matchedText: "Solo")])
        #expect(terms == [SensitiveTerm(text: "Solo", requiresTokenBoundary: true)])
    }

    @Test("piiScan region: category label stays out; matched text carries the terms")
    func piiScanLabelExcluded() {
        // After the PD-3 stamp a piiScan-applied region's metadata carries
        // .pii(category) while its Source keeps the label as `term` — the
        // label ("Name") must not become a sensitive term.
        let region = seededRegion(
            .searchMatch(term: "Name", rationale: detectorRationale()))
        let terms = termTable(PipelineCoordinator.sensitiveTerms(
            fromAppliedRegions: [0: [region]],
            metadata: [region.id: .mock(piiKind: .pii(.name), matchedText: "DELIA")]))
        #expect(terms["Name"] == nil, "category label must not enter the term set")
        #expect(terms["DELIA"] == true, "single-token name matched text carries the boundary flag")
    }

    @Test("User-term region: the \"Custom\" placeholder stays out; matched text kept")
    func userTermPlaceholderExcluded() {
        // piiScan user-term (always-flag) rows stamp term = "Custom" with a
        // rationale attached — a placeholder, not document content, and a
        // substring of everyday words ("Customer").
        let region = seededRegion(
            .searchMatch(term: "Custom", rationale: detectorRationale("user.alwaysFlag")))
        let terms = termTable(PipelineCoordinator.sensitiveTerms(
            fromAppliedRegions: [0: [region]],
            metadata: [region.id: .mock(
                piiKind: .searchMatch(term: "Custom"), matchedText: "ACME-4471")]))
        #expect(terms["Custom"] == nil, "placeholder term must not enter the term set")
        #expect(terms["ACME-4471"] == false)
    }

    @Test("Typed query text also matched as a single-token name keeps substring matching")
    func dedupKeepsLeastRestrictiveDiscipline() {
        // The user explicitly searched for "Delia" (typed row) AND a piiScan
        // name region matched the same text: the typed contribution wins —
        // plain substring matching.
        let typed = seededRegion(.searchMatch(term: "Delia"))
        let scanned = seededRegion(
            .searchMatch(term: "Name", rationale: detectorRationale()))
        let terms = termTable(PipelineCoordinator.sensitiveTerms(
            fromAppliedRegions: [0: [typed, scanned]],
            metadata: [
                typed.id: .mock(piiKind: .searchMatch(term: "Delia"), matchedText: "Delia"),
                scanned.id: .mock(piiKind: .pii(.name), matchedText: "Delia"),
            ]))
        #expect(terms["Delia"] == false)
    }

    @Test("isSingleToken splits on whitespace")
    func singleToken() {
        #expect(PipelineCoordinator.isSingleToken("Hartwell"))
        #expect(!PipelineCoordinator.isSingleToken("Delia Hartwell"))
        #expect(!PipelineCoordinator.isSingleToken("P.O. Box"))
    }
}
