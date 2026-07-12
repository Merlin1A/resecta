import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// TEST §2.13, PHASE_12_PLAN — Shared test tags, mock factories, and pipeline helper.

// MARK: - Shared Tags

extension Tag {
    /// Security-critical tests — redaction correctness, data leakage prevention.
    @Tag static var security: Self
    /// Tests that must never regress — pixel destruction, coordinate conversion.
    @Tag static var critical: Self
    /// Sandwich (Searchable Redaction) pipeline tests.
    @Tag static var sandwich: Self
    /// Pipeline coordination and orchestration tests.
    @Tag static var coordination: Self
}

// MARK: - Mock Factories (TEST §2.13)

extension VerificationReport {
    /// Create a mock report with the given overall status.
    /// Uses empty layers array — tests needing specific layers should
    /// construct LayerResult arrays directly.
    static func mock(status: VerificationStatus) -> VerificationReport {
        VerificationReport(layers: [], overallStatus: status, durationSeconds: 0)
    }
}

extension RedactionRegion {
    /// Create a mock manual redaction region.
    static func mock(
        rect: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05)
    ) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual)
    }
}

extension DetectionResult {
    /// Create a mock detection result of the given kind.
    static func mock(
        kind: DetectionResult.Kind = .pii(.ssn),
        matchedText: String? = nil,
        recognitionLevel: DetectionResult.RecognitionLevel = .fast
    ) -> DetectionResult {
        DetectionResult(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.04),
            kind: kind,
            confidence: 0.95,
            matchedText: matchedText,
            recognitionLevel: recognitionLevel
        )
    }
}

extension PageFilterDigest {
    /// Create a mock digest for testing Layer 7 character count cross-check.
    static func mock(
        pageIndex: Int = 0,
        extracted: Int = 100,
        excluded: Int = 20,
        surviving: Int = 80
    ) -> PageFilterDigest {
        PageFilterDigest(
            pageIndex: pageIndex,
            extractedCount: extracted,
            excludedCount: excluded,
            survivingCount: surviving,
            boundaryCharacters: []
        )
    }
}

extension LayerResult {
    /// Create a mock layer result for status derivation tests (TEST §4.7).
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

// MARK: - Sample bank-statement fixture (S01)

/// The shipped first-run demo statement (`~/resecta/Resources/SampleDocument.pdf`,
/// produced by the `~/resecta-sample-doc` generator), committed here as an
/// engine fixture so the dual-leg Stage-1 detection snapshot — revision-plan G1
/// / handoff H2 — can run (`SampleStatementSnapshotTests`). FROZEN: byte-
/// identical to the app-bundle copy (three names, ONE SHA — app
/// `SampleDocument.pdf` · engine `sample-bank-statement.pdf` · generator
/// `sample-bank-statement.pdf`). The dual-copy identity guard spans the engine
/// test (SHA, below), `ResectaAppTests/BundleContentsTests` (app copy SHA), and
/// `Scripts/audit-lint.sh` (commit-time `cmp` of the two repo bytes, M-9).
///
/// Unlike a real-document tax fixture, this statement is FULLY SYNTHETIC with a
/// public, fixture-disclosed value set, so test
/// diagnostics MAY log matched text here (the W2 logging exemption — see the
/// snapshot suite header). Production logging rules (ARCH §12.2) are unchanged.
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

// MARK: - Hartwell loan-packet fixture (S05)

/// The synthetic Hartwell loan/mortgage application packet (12 pp), emitted by
/// the `~/resecta-sample-doc` generator (`python -m packet.build_packet`) and
/// committed here as the engine's primary labeled test corpus (INV-2).
/// One-pass BYTE-DETERMINISTIC: a committed fixture must
/// match a fresh generator run (S04). Page order (0-indexed): 0,1 URLA-B |
/// 2 URLA-A | 3,4,5 STMT (embedded frozen statement) | 6,7 T1040 | 8 ACH |
/// 9 W-2 | 10 GOV-ID | 11 VEH (.generic).
///
/// Three committed companions in `TestResources/`:
///  - `packet.pdf`                    -- the pristine born-digital packet.
///  - `packet-scan-sim-150dpi.pdf`    -- image-only render (0 extractable text);
///                                       the OCR-leg path (S06 OCR role).
///  - `packet-ground-truth.json`      -- the draw-time D21 ground truth: 106
///    drawn occurrences (`occurrences[]`) + 20 carried STMT classes
///    (`carried_stmt[]`). bbox is normalized 0-1, BOTTOM-LEFT origin, CORNER
///    form `[x0,y0,x1,y1]` (NOT the engine's origin+size `normalizedRect`
///    `[x,y,w,h]` -- same coordinate SYSTEM, different box ENCODING; the P/R
///    harness converts). `expectation` carries the four-tier label
///    (must_fire / must_not_fire / should_fire / watch).
///
/// Fully synthetic with a public values manifest, so
/// test diagnostics MAY log matched text here (D31; same exemption as the
/// sample statement). Production logging rules (ARCH 12.2) are unchanged.
extension TestFixtures {

    enum LoanPacketFixtureError: Error { case missingResource }

    /// SHA-256 identity pins (a silent fixture substitution must be loud).
    static let loanPacketSHA256 =
        "362375692b8cff378d66c43fcf46f00ba09e1ea982602fcc5c8b70e96f54339a"
    static let loanPacketScanSimSHA256 =
        "9af85bcef11b7e0cc14db1b43040f0cc121482598a8f5174296775268bf51874"
    static let loanPacketGroundTruthSHA256 =
        "6961dbf0cec87fd0f24c98dc56d34bef44b770f7810052ea454af2e7da97f59a"

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

    /// Load the draw-time D21 ground-truth JSON (consumed by the P/R harness).
    static func loanPacketGroundTruthJSON() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "packet-ground-truth",
            withExtension: "json",
            subdirectory: "TestResources"
        ) else { throw LoanPacketFixtureError.missingResource }
        return try Data(contentsOf: url)
    }
}

// MARK: - Layer-2 fill-hallucination fixture (Part A, S1)

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
/// before commit (S1 §2b): 0 selectable text on every page; only Apple auto-injected
/// metadata (`Producer`/`CreationDate`/`ModDate`); no email/SSN/phone-shaped bytes;
/// the only residual visible text is the synthetic Sablebrook Bank "SAMPLE DOCUMENT"
/// content (no real person). Permanent regression fixture (maintainer-approved 2026-06-27).
/// SHA-256 ed85bcbc1405b5263e387c6c543863e3494a821308ae81d71105a0c0a337999d.
/// See plans/resecta-partA-verifier-guard-2026-06-27/.
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
    /// components of each page image and visually verified (S1 §2e).
    static func fillHallucinationRegionsJSON() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "secureraster-fill-hallucination-regions",
            withExtension: "json",
            subdirectory: "TestResources"
        ) else { throw FillHallucinationFixtureError.missingResource }
        return try Data(contentsOf: url)
    }
}

// MARK: - TestPipeline (PHASE_12_PLAN)

/// Pipeline helper for integration and security regression tests.
/// Runs the full rasterize → reconstruct pipeline on fixture data
/// and returns a URL to the output PDF.
///
/// nonisolated — matches engine package default isolation.
/// No MainActor dependency.
enum TestPipeline {

    enum TestPipelineError: Error {
        case invalidFixture
        case rasterizationFailed(pageIndex: Int)
    }

    /// Process fixture PDF data through the redaction pipeline and return output URL.
    ///
    /// Bypasses `os_proc_available_memory()` check in `rasterize()` since simulator
    /// memory is unpredictable. Uses `renderPage()` directly + manual fill/verify
    /// to replicate the core pipeline path without the memory gate.
    ///
    /// - Parameters:
    ///   - fixtureData: Raw PDF bytes from a TestFixtures generator.
    ///   - mode: Pipeline mode (default: secureRasterization).
    ///   - regions: Per-page regions. If nil, a default center-strip region is created per page.
    ///   - fillColor: Fill color for redaction (default: black).
    ///   - dpi: Render DPI (default: 150 for test speed). See PHASE_12_PLAN.
    /// - Returns: URL to the output PDF. Caller must clean up with `defer`.
    static func processAndExport(
        _ fixtureData: Data,
        mode: PipelineMode = .secureRasterization,
        regions: [Int: [RedactionRegion]]? = nil,
        fillColor: FillColor = .black,
        dpi: Int = 150
    ) async throws -> URL {
        guard let doc = PDFDocument(data: fixtureData) else {
            throw TestPipelineError.invalidFixture
        }

        let pageCount = doc.pageCount
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_pipeline_\(UUID().uuidString).pdf")

        let rasterizer = PageRasterizer()
        let reconstructor = PDFStreamReconstructor(tempURL: tempURL)

        var firstPage = true
        for pageIndex in 0..<pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }

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

            // Render page directly (bypasses os_proc_available_memory check)
            let renderedImage = try await rasterizer.renderPage(
                page, pageIndex: pageIndex, dpi: CGFloat(dpi)
            )

            // Create mutable context, draw rendered image, apply fills
            let width = renderedImage.width
            let height = renderedImage.height
            guard let ctx = createBitmapContext(width: width, height: height) else {
                throw TestPipelineError.rasterizationFailed(pageIndex: pageIndex)
            }
            ctx.draw(renderedImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            // Apply and verify fills (ENGINE §3.1, §3.4)
            try applyRedactionFills(context: ctx, regions: pageRegions, fillColor: fillColor)

            for region in pageRegions {
                let pixelRect = normalizedToFillPixels(
                    region.normalizedRect, bitmapWidth: width, bitmapHeight: height
                )
                let clamped = pixelRect.intersection(
                    CGRect(x: 0, y: 0, width: width, height: height)
                )
                guard !clamped.isEmpty, try verifyFill(
                    context: ctx, rect: clamped,
                    expectedColor: fillColor.expectedPixel
                ) else {
                    throw TestPipelineError.rasterizationFailed(pageIndex: pageIndex)
                }
            }

            guard let redactedImage = ctx.makeImage() else {
                throw TestPipelineError.rasterizationFailed(pageIndex: pageIndex)
            }

            // For searchable redaction, extract and filter characters
            var textLayerEntries: [CharacterInfo]? = nil
            if mode == .searchableRedaction {
                let extractor = TextLayerExtractor()
                if let characters = try? await extractor.extractCharacters(from: page),
                   !characters.isEmpty {
                    // CAT-353/366 (D-34): region basis is the zero-origin
                    // DISPLAYED output page (effectiveSize), matching the
                    // rotation-applied cropBox-local character bounds
                    // extractCharacters now produces — mirrors production
                    // PageRasterizer. Identical to the raw cropBox for a
                    // zero-origin unrotated page; correct for rotated/offset.
                    let regionBasis = CGRect(
                        origin: .zero,
                        size: effectiveBounds(page.bounds(for: .cropBox), rotation: page.rotation).size
                    )
                    let redactionRectsInPoints = pageRegions.map {
                        normalizedToPDFPageCoordinates($0.normalizedRect, pageRect: regionBasis)
                    }
                    let filterResult = try await filterCharacters(
                        characters: characters,
                        redactionRects: redactionRectsInPoints
                    )
                    textLayerEntries = filterResult.surviving
                }
            }

            // Use point dimensions (not pixel) for the PDF media box,
            // matching the production PageRasterizer behavior.
            let pageBounds = page.bounds(for: .cropBox)
            let pointSize = effectiveBounds(pageBounds, rotation: page.rotation).size
            let pageOutput = PageOutput(
                image: redactedImage,
                size: pointSize,
                textLayerEntries: textLayerEntries
            )

            if firstPage {
                try await reconstructor.begin(firstPageSize: pointSize)
                firstPage = false
            }
            try await reconstructor.appendPage(pageOutput)
        }

        await reconstructor.finalize()
        return tempURL
    }

    /// Compute the per-page `PageFilterDigest` array for a fixture under the
    /// SAME extraction + filtering `processAndExport` performs in
    /// `.searchableRedaction` mode. Filtering is deterministic, so the digests
    /// returned here match the exported invisible text layer whenever this is
    /// called with the same `regions` as the `processAndExport` run.
    ///
    /// `processAndExport` returns only the output URL and discards the filter
    /// digests; Layers 7 (Character Count) and 9 (Character Lineage) require
    /// the per-page `PageFilterDigest`, so the S01 measurement harness surfaces
    /// them here via `FilterResult.toDigest(pageIndex:redactionRects:safetyMargin:)`.
    /// Test-only and purely additive — the production helper is unchanged.
    static func searchableDigests(
        _ fixtureData: Data,
        regions: [Int: [RedactionRegion]]? = nil
    ) async throws -> [PageFilterDigest?] {
        guard let doc = PDFDocument(data: fixtureData) else {
            throw TestPipelineError.invalidFixture
        }
        let pageCount = doc.pageCount
        var digests: [PageFilterDigest?] = Array(repeating: nil, count: pageCount)
        let extractor = TextLayerExtractor()
        for pageIndex in 0..<pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }
            // Mirror processAndExport's region defaulting exactly so a nil
            // `regions` argument produces digests consistent with that helper.
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
            guard let characters = try? await extractor.extractCharacters(from: page),
                  !characters.isEmpty else { continue }
            // CAT-353/366 (D-34): zero-origin DISPLAYED region basis, mirroring
            // processAndExport and production PageRasterizer (see above).
            let regionBasis = CGRect(
                origin: .zero,
                size: effectiveBounds(page.bounds(for: .cropBox), rotation: page.rotation).size
            )
            let redactionRectsInPoints = pageRegions.map {
                normalizedToPDFPageCoordinates($0.normalizedRect, pageRect: regionBasis)
            }
            let filterResult = try await filterCharacters(
                characters: characters,
                redactionRects: redactionRectsInPoints
            )
            digests[pageIndex] = filterResult.toDigest(
                pageIndex: pageIndex,
                redactionRects: redactionRectsInPoints,
                safetyMargin: safetyMarginPoints
            )
        }
        return digests
    }
}
