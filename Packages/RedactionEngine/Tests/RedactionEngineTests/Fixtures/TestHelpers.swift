import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// Shared test tags, mock factories, and pipeline helper.

// MARK: - Shared Tags

extension Tag {
    /// Security-critical tests — redaction correctness, data leakage prevention.
    @Tag static var security: Self
    /// Tests that must never regress — pixel destruction, coordinate conversion.
    @Tag static var critical: Self
    /// Sandwich (Searchable Redaction) pipeline tests.
    @Tag static var sandwich: Self
}

// MARK: - Mock Factories

extension RedactionRegion {
    /// Create a mock manual redaction region.
    static func mock(
        rect: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05)
    ) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual)
    }
}

extension LayerResult {
    /// Create a mock layer result for status derivation tests.
    static func mock(status: VerificationStatus) -> LayerResult {
        LayerResult(
            name: "Mock Layer",
            symbolName: "circle",
            status: status,
            shortDescription: "Mock",
            detailDescription: "Mock layer for testing",
            pageReferences: nil,
            durationSeconds: 0
        )
    }
}

// MARK: - Sample bank-statement fixture

/// The shipped first-run demo statement (the app bundle's
/// `SampleDocument.pdf`, produced by the sample-document generator),
/// committed here as an engine fixture so the dual-leg Stage-1 detection
/// snapshot can run (`SampleStatementSnapshotTests`). FROZEN: byte-
/// identical to the app-bundle copy (three names, ONE SHA — app
/// `SampleDocument.pdf` · engine `sample-bank-statement.pdf` · generator
/// `sample-bank-statement.pdf`). The dual-copy identity guard spans the engine
/// test (SHA, below), `ResectaAppTests/BundleContentsTests` (app copy SHA), and
/// `Scripts/audit-lint.sh` (commit-time `cmp` of the two repo bytes, AL-3).
///
/// Unlike a real-document tax fixture, this statement is FULLY SYNTHETIC with a
/// public, fixture-disclosed value set, so test
/// diagnostics MAY log matched text here (the synthetic-fixture logging
/// exemption — see the snapshot suite header). Production logging rules
/// are unchanged.
extension TestFixtures {

    enum SampleStatementFixtureError: Error { case missingResource }

    /// SHA-256 of the committed sample-statement fixture (identity pin). The app
    /// half (`BundleContentsTests`) duplicates this literal with a cross-
    /// reference (it cannot import this target); `audit-lint.sh` is the byte
    /// backstop.
    static let sampleStatementSHA256 =
        "992ca0543eb1a2eaab8d8dba0a4ad4b8339cf95b804a0347ab1b0987ce18fa20"

    /// Page count of the committed sample-statement fixture (identity pin).
    static let sampleStatementPageCount = 3

    /// Load the committed sample bank-statement fixture from the test bundle.
    static func sampleStatementPDF() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "sample-bank-statement",
            withExtension: "pdf",
            subdirectory: "TestResources"
        ) else { throw SampleStatementFixtureError.missingResource }
        return try Data(contentsOf: url)
    }
}

// MARK: - Hartwell loan-packet fixture

/// The synthetic Hartwell loan/mortgage application packet (12 pp), emitted by
/// the sample-document generator (`python -m packet.build_packet`) and
/// committed here as the engine's primary labeled test corpus.
/// One-pass BYTE-DETERMINISTIC: a committed fixture must
/// match a fresh generator run. Page order (0-indexed): 0,1 URLA-B |
/// 2 URLA-A | 3,4,5 STMT (embedded frozen statement) | 6,7 T1040 | 8 ACH |
/// 9 W-2 | 10 GOV-ID | 11 VEH (.generic).
///
/// Three committed companions in `TestResources/`:
///  - `packet.pdf`                    -- the pristine born-digital packet.
///  - `packet-scan-sim-150dpi.pdf`    -- image-only render (0 extractable text);
///                                       the OCR-leg path.
///  - `packet-ground-truth.json`      -- the draw-time ground truth: 106
///    drawn occurrences (`occurrences[]`) + 20 carried STMT classes
///    (`carried_stmt[]`). bbox is normalized 0-1, BOTTOM-LEFT origin, CORNER
///    form `[x0,y0,x1,y1]` (NOT the engine's origin+size `normalizedRect`
///    `[x,y,w,h]` -- same coordinate SYSTEM, different box ENCODING; the P/R
///    harness converts). `expectation` carries the four-tier label
///    (must_fire / must_not_fire / should_fire / watch).
///
/// Fully synthetic with a public values manifest, so
/// test diagnostics MAY log matched text here (same exemption as the
/// sample statement). Production logging rules are unchanged.
extension TestFixtures {

    enum LoanPacketFixtureError: Error { case missingResource }

    /// SHA-256 identity pins (a silent fixture substitution must be loud).
    static let loanPacketSHA256 =
        "362375692b8cff378d66c43fcf46f00ba09e1ea982602fcc5c8b70e96f54339a"
    static let loanPacketScanSimSHA256 =
        "9af85bcef11b7e0cc14db1b43040f0cc121482598a8f5174296775268bf51874"
    static let loanPacketGroundTruthSHA256 =
        "dbbf59b3a769a36e61178a5ccdf2e38b421fb266052183924960eba871874383"

    /// Page count of the committed loan-packet fixture (identity pin).
    static let loanPacketPageCount = 12

    /// Load the pristine 12-page loan packet from the test bundle.
    static func loanPacketPDF() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "packet",
            withExtension: "pdf",
            subdirectory: "TestResources"
        ) else { throw LoanPacketFixtureError.missingResource }
        return try Data(contentsOf: url)
    }

    /// Load the image-only (scan-sim, 150 DPI) loan packet -- the OCR-leg path.
    static func loanPacketScanSimPDF() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "packet-scan-sim-150dpi",
            withExtension: "pdf",
            subdirectory: "TestResources"
        ) else { throw LoanPacketFixtureError.missingResource }
        return try Data(contentsOf: url)
    }

    /// Load the draw-time ground-truth JSON (consumed by the P/R harness).
    static func loanPacketGroundTruthJSON() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "packet-ground-truth",
            withExtension: "json",
            subdirectory: "TestResources"
        ) else { throw LoanPacketFixtureError.missingResource }
        return try Data(contentsOf: url)
    }
}

// MARK: - Layer-2 fill-hallucination fixture (Part A)

/// The Secure-Rasterization OUTPUT that reproduces the Part A Layer-2
/// fill-hallucination verifier false positive: the bars are solid, pixel-exact,
/// `verifyFill`-proven black, yet the frozen `verificationLayer2` preset (`.fast`,
/// `usesLanguageCorrection = false`, conf ≥ 0.50) OCRs the rasterized output and
/// Vision hallucinates short tokens ("rn", "W", "IWI", "w") OUT OF the bars; their
/// word boxes are ≥ `inRegionCoverageThreshold` (0.5) inside the (correct) region
/// rects, so `classifyPageOCR` → `.textInRegion` → in `.secureRasterization` a FAIL.
/// Reproduces in-region FAIL on pages 2,3 / page 1 clean on iOS 26.4. The fix
/// (PR #2) makes a hit count as in-region only when it carries actual surviving ink.
///
/// PROVENANCE: the redaction of the synthetic `resecta-sample-doc` bank statement
/// (the standard "DELIA HARTWELL" corpus identity) — NOT a real document. PII-gated
/// before commit: 0 selectable text on every page; only Apple auto-injected
/// metadata (`Producer`/`CreationDate`/`ModDate`); no email/SSN/phone-shaped bytes;
/// the only residual visible text is the synthetic Sablebrook Bank "SAMPLE DOCUMENT"
/// content (no real person). Permanent regression fixture.
/// SHA-256 ed85bcbc1405b5263e387c6c543863e3494a821308ae81d71105a0c0a337999d.
extension TestFixtures {

    enum FillHallucinationFixtureError: Error { case missingResource }

    /// Load the Part A fill-hallucination reproducer (secure-raster output PDF).
    static func fillHallucinationRedactedPDF() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "secureraster-fill-hallucination",
            withExtension: "pdf",
            subdirectory: "TestResources"
        ) else { throw FillHallucinationFixtureError.missingResource }
        return try Data(contentsOf: url)
    }

    /// Load the committed painted-bar region rects for the fixture (per page,
    /// 0-indexed; normalized bottom-left, RedactionRegion.normalizedRect form).
    /// The fixture is output-only (no redaction session), so Layer-2's `regions:`
    /// argument is supplied from these. Extracted once from the solid-fill
    /// components of each page image and visually verified.
    static func fillHallucinationRegionsJSON() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "secureraster-fill-hallucination-regions",
            withExtension: "json",
            subdirectory: "TestResources"
        ) else { throw FillHallucinationFixtureError.missingResource }
        return try Data(contentsOf: url)
    }
}

// MARK: - TestPipeline

/// Pipeline helper for integration and security regression tests.
/// Runs the full rasterize → reconstruct pipeline on fixture data
/// and returns a URL to the output PDF.
///
/// nonisolated — matches engine package default isolation.
/// No MainActor dependency.
enum TestPipeline {

    enum TestPipelineError: Error {
        case invalidFixture
    }

    /// Process fixture PDF data through the production page loop and return
    /// the output URL: every page through `PageRasterizer.rasterize(_:dpiCap:)`
    /// (its memory gate passes on the simulator) and `PDFStreamReconstructor`,
    /// via `ProductionPageLoop.runRedaction`.
    ///
    /// Every page takes the caller's `mode`, except that a page with no text
    /// layer is rasterized in Secure mode: the rasterizer accepts a Searchable
    /// page only when it carries text.
    ///
    /// - Parameters:
    ///   - fixtureData: Raw PDF bytes from a TestFixtures generator.
    ///   - mode: Pipeline mode (default: secureRasterization).
    ///   - regions: Per-page regions. If nil, a default center-strip region is created per page.
    ///   - fillColor: Fill color for redaction (default: black).
    ///   - dpi: The page's target DPI and the loop's DPI cap (default: 150 for test speed).
    /// - Returns: URL to the output PDF. Caller must clean up with `defer`.
    static func processAndExport(
        _ fixtureData: Data,
        mode: PipelineMode = .secureRasterization,
        regions: [Int: [RedactionRegion]]? = nil,
        fillColor: FillColor = .black,
        dpi: Int = 150
    ) async throws -> URL {
        try await productionRun(
            fixtureData, mode: mode, regions: regions, fillColor: fillColor, dpi: dpi).url
    }

    /// The run behind `processAndExport`: the output URL and the production
    /// loop's outcome (its per-page filter digests and modes).
    static func productionRun(
        _ fixtureData: Data,
        mode: PipelineMode,
        regions: [Int: [RedactionRegion]]?,
        fillColor: FillColor = .black,
        dpi: Int = 150
    ) async throws -> (url: URL, outcome: ProductionPageLoop.RedactionOutcome) {
        guard let doc = PDFDocument(data: fixtureData) else {
            throw TestPipelineError.invalidFixture
        }
        let hasHiddenOCG = CGDataProvider(data: fixtureData as CFData)
            .flatMap { CGPDFDocument($0) }
            .map { TextLayerExtractor.documentHasHiddenOCG($0) } ?? false

        let pages: [PDFPageData] = (0..<doc.pageCount).compactMap { pageIndex in
            guard let page = doc.page(at: pageIndex) else { return nil }

            // Use provided regions or create a default center-strip per page
            let pageRegions: [RedactionRegion]
            if let regions {
                pageRegions = regions[pageIndex] ?? []
            } else {
                pageRegions = [
                    RedactionRegion(
                        id: UUID(),
                        normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05),
                        source: .manual
                    )
                ]
            }

            let hasText = page.string?.isEmpty == false
            let pageMode: PipelineMode =
                mode == .searchableRedaction && hasText ? .searchableRedaction : .secureRasterization
            return PDFPageData(
                page: page, pageIndex: pageIndex, regions: pageRegions,
                fillColor: fillColor, targetDPI: dpi, pipelineMode: pageMode,
                rotation: page.rotation, hasHiddenOCG: hasHiddenOCG,
                cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef,
                hasText: pageMode == .searchableRedaction)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_pipeline_\(UUID().uuidString).pdf")
        let outcome = try await ProductionPageLoop.runRedaction(
            pages: pages, outputURL: outputURL, dpiCap: dpi)
        return (outputURL, outcome)
    }

    /// The per-page `PageFilterDigest` array the production page loop
    /// reports for a fixture in `.searchableRedaction` mode with these
    /// `regions` (nil = the default strip, as in `processAndExport`): the
    /// digests behind the text layer `processAndExport` writes for the same
    /// call, nil for a page written without a text layer. Layers 7
    /// (Character Count) and 9 (Character Lineage) read them.
    static func searchableDigests(
        _ fixtureData: Data,
        regions: [Int: [RedactionRegion]]? = nil
    ) async throws -> [PageFilterDigest?] {
        let run = try await productionRun(fixtureData, mode: .searchableRedaction, regions: regions)
        try? FileManager.default.removeItem(at: run.url)
        return run.outcome.filterDigests
    }
}

// MARK: - TestGate: the visible environmental skip

/// The one shape for a test that cannot run in this environment (a runtime
/// asset that is not provisioned, an emitter whose output path is not
/// requested, a host without the cores a measurement needs). The gate
/// records a warning-severity issue — visible in the xcresult and the log,
/// never a failure — so a run that skipped a body is distinguishable from a
/// run that proved something. A resource that IS tracked in the repository
/// (a fixture JSON, a bundled gazetteer, a value the test computes itself)
/// is not a gate: it is `try #require`, and its absence fails the test.
enum TestGate {
    /// Record the skip and let the caller `return`. The `return` stays at the
    /// call site so the compiler still sees the early exit.
    static func skip(_ reason: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        Issue.record(reason, severity: .warning, sourceLocation: sourceLocation)
    }
}
