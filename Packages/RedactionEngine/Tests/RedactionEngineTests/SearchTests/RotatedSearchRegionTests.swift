import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// S15 CAT-353 — task 4: region-orientation probes for the two SEARCH-side
// region producers on rotated pages (C-C deep-plan §6, ADV-2 A2-8).
//
//  • Text search → `DocumentSearcher.boundingRect(for:page:)` maps PDFKit's
//    absolute (MediaBox) selection bounds into cropBox-LOCAL space — it now
//    subtracts `pageBounds.origin` (CAT-366 parity with TextLayerExtractor,
//    D01-F2) BEFORE the rotation mirror, so it is origin-aware. These tests pin
//    it across rotation × CropBox origin, both at the producer (centre-tolerance)
//    and end to end through export. The offset-origin export guards assert
//    TERM-ABSENCE in the output (not Layer-2 status — the .searchableRedaction
//    → .info continuity, CAT-351, can mask an offset-page leak).
//  • OCR PII detection → `scanPagePIIViaOCR` / `ocrPage` request the page
//    thumbnail. At the pin the size came from the UNROTATED cropBox, so PDFKit
//    aspect-fit/letterboxed the rotation-applied render and shifted every OCR
//    `normalizedRect` (A2-8). The fix routes all three OCR-thumbnail sites
//    through `DocumentSearcher.ocrThumbnailSize`, which uses DISPLAYED dims.
//
// The UI-drawn overlay producer (A2-8 path (a)) normalizes in displayed space
// by construction (overlay over PDFView's displayed page); it lives in the app
// target and has no engine-test surface — see the exit note for
// the operator-side device confirmation. The engine matrix's seeded
// displayed-space regions (RotatedPageCoordinateTests) exercise the same
// contract the overlay feeds.
@Suite("Rotated Search Region Orientation", .tags(.security, .critical))
struct RotatedSearchRegionTests {

    private let engine = VerificationEngine()

    /// Test-local, independent A2-7 transform (CropBox-local → displayed),
    /// used to position the EXPECTED region without reusing production code.
    private func displayedRect(_ r: CGRect, sourceSize s: CGSize, rotation: Int) -> CGRect {
        let x = r.minX, y = r.minY, wr = r.width, hr = r.height
        let w = s.width, h = s.height
        switch ((rotation % 360) + 360) % 360 {
        case 90:  return CGRect(x: y, y: w - x - wr, width: hr, height: wr)
        case 180: return CGRect(x: w - x - wr, y: h - y - hr, width: wr, height: hr)
        case 270: return CGRect(x: h - y - hr, y: x, width: hr, height: wr)
        default:  return r
        }
    }

    private func unionBounds(_ rects: [CGRect]) -> CGRect {
        guard var u = rects.first else { return .zero }
        for r in rects.dropFirst() { u = u.union(r) }
        return u
    }

    /// MARKER's local (unrotated) bounds + glyph count, measured from the
    /// zero-origin r=0 fixture (T_rot identity there).
    private func markerLocalBounds() async throws -> CGRect {
        let doc = try #require(PDFDocument(data: TestFixtures.rotatedTextPDF(rotation: 0)))
        let page = try #require(doc.page(at: 0))
        let chars = try await TextLayerExtractor().extractCharacters(from: page)
        let marker = chars.filter { $0.bounds.minX >= 300 }.map(\.bounds)
        #expect(!marker.isEmpty, "reference fixture must contain MARKER glyphs")
        return unionBounds(marker)
    }

    // --- A2-8 fix guard: thumbnail size uses DISPLAYED (effective) dims ---
    @Test("ocrThumbnailSize requests displayed (effective) dims (CAT-353 / A2-8)",
          arguments: [0, 90, 180, 270])
    func ocrThumbnailSizeUsesEffectiveDimensions(rotation: Int) {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let scale: CGFloat = 300.0 / 72.0
        let size = DocumentSearcher.ocrThumbnailSize(pageBounds: bounds, rotation: rotation)
        if rotation == 90 || rotation == 270 {
            // Displayed page is landscape — the request must be transposed so
            // PDFKit does not letterbox the rotation-applied render.
            #expect(abs(size.width - 792 * scale) < 0.01 && abs(size.height - 612 * scale) < 0.01,
                    "r=\(rotation): thumbnail size must use swapped (displayed) dims")
        } else {
            #expect(abs(size.width - 612 * scale) < 0.01 && abs(size.height - 792 * scale) < 0.01,
                    "r=\(rotation): thumbnail size must equal cropBox dims")
        }
        // Pixel budget is rotation-invariant — the memory guards are unaffected.
        let unrotated = DocumentSearcher.ocrThumbnailSize(pageBounds: bounds, rotation: 0)
        #expect(abs(size.width * size.height - unrotated.width * unrotated.height) < 1,
                "r=\(rotation): the W↔H swap must not change the pixel budget")
    }

    // --- Text-search region producer stays displayed-space under rotation ---
    @Test("boundingRect maps a search match into displayed space across CropBox origins",
          arguments: [0, 90, 180, 270], [CGPoint.zero, CGPoint(x: 50, y: 50)])
    func searchSourcedRegionMatchesDisplayedLocation(rotation: Int, origin: CGPoint) async throws {
        let source = TestFixtures.rotatedTextBaseSize
        // The expected position is origin-INDEPENDENT: markerLocalBounds() reads
        // the zero-origin r=0 reference and `displayedRect` maps local→displayed,
        // so a CropBox origin shift must NOT move the expected normalized centre.
        // An origin-aware boundingRect (D01-F2) still lands on it; the pre-fix
        // producer lands off by ~(ox/W, oy/H) on the non-zero-origin cases.
        let markerLocal = try await markerLocalBounds()
        let effective = effectiveBounds(
            CGRect(origin: .zero, size: source), rotation: rotation
        ).size
        let expected = displayedRect(markerLocal, sourceSize: source, rotation: rotation)
        let expectedNorm = CGRect(
            x: expected.minX / effective.width, y: expected.minY / effective.height,
            width: expected.width / effective.width, height: expected.height / effective.height
        )

        let doc = try #require(PDFDocument(data:
            TestFixtures.rotatedTextPDF(rotation: rotation, cropBoxOrigin: origin)))
        let page = try #require(doc.page(at: 0))
        let text = try #require(page.string) as NSString
        let range = text.range(of: "MARKER")
        #expect(range.location != NSNotFound, "fixture must contain the MARKER token")

        let region = try #require(
            DocumentSearcher().boundingRect(for: range, page: page),
            "boundingRect must produce a region for the MARKER match"
        )
        // The search-sourced region must land on MARKER's DISPLAYED location
        // (centre within tolerance) — not the unrotated or origin-shifted location.
        let dcx = abs(region.midX - expectedNorm.midX)
        let dcy = abs(region.midY - expectedNorm.midY)
        #expect(dcx < 0.04 && dcy < 0.04,
                "r=\(rotation) origin=(\(Int(origin.x)),\(Int(origin.y))): search region centre \((region.midX, region.midY)) must match displayed MARKER \((expectedNorm.midX, expectedNorm.midY))")
    }

    // --- Search-sourced region → export → OCR-clean (literal task-4(b)) ---
    @Test("Search-sourced region on a rotated page exports OCR-clean (Layer 2)")
    func searchSourcedRegionExportIsOCRClean() async throws {
        let data = TestFixtures.rotatedTextPDF(rotation: 90)
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let text = try #require(page.string) as NSString
        let range = text.range(of: "MARKER")
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: try #require(DocumentSearcher().boundingRect(for: range, page: page)),
            source: .manual
        )

        let outURL = try await TestPipeline.processAndExport(
            data, mode: .searchableRedaction, regions: [0: [region]]
        )
        defer { try? FileManager.default.removeItem(at: outURL) }
        let outDoc = try #require(PDFDocument(url: outURL))

        // Layer 2 (OCR Check, index 1) re-rasterizes and OCRs the region of the
        // OUTPUT and searches for the term: a correctly placed search region
        // means the pixels under it are destroyed and the term is gone.
        let l2 = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(outDoc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: ["MARKER"],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil], perPageModes: [.searchableRedaction]
        )
        #expect(!l2.status.isFail,
                "Layer 2 OCR must be clean under a search-sourced region on a /Rotate 90 page")
    }

    // --- D01-F1: search-sourced region → export → term-absent across CropBox
    //     origins on a /Rotate 90 page. Complements the rotation-0 D08-F3 guard
    //     by exercising the rotation × origin INTERSECTION of the localize-then-
    //     rotate transform. Asserts TERM-ABSENCE (not !l2.status.isFail) — the
    //     .searchableRedaction → .info continuity (CAT-351) can mask a leak. ---
    @Test("Search-sourced region exports term-absent across CropBox origins on a /Rotate 90 page",
          arguments: [CGPoint.zero, CGPoint(x: 50, y: 50)])
    func searchSourcedRegionExportTermAbsentOnOffsetRotatedPage(origin: CGPoint) async throws {
        let data = TestFixtures.rotatedTextPDF(rotation: 90, cropBoxOrigin: origin)
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let label = "r=90 origin=(\(Int(origin.x)),\(Int(origin.y)))"

        let text = try #require(page.string) as NSString
        let range = text.range(of: "MARKER")
        #expect(range.location != NSNotFound, "\(label): fixture must contain MARKER")
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: try #require(
                DocumentSearcher().boundingRect(for: range, page: page),
                "\(label): boundingRect must produce a region for MARKER"),
            source: .manual
        )

        let outURL = try await TestPipeline.processAndExport(
            data, mode: .searchableRedaction, regions: [0: [region]]
        )
        defer { try? FileManager.default.removeItem(at: outURL) }
        let outDoc = try #require(PDFDocument(url: outURL))
        let outPage = try #require(outDoc.page(at: 0))

        let outString = (outPage.string ?? "") as NSString
        #expect(outString.range(of: "MARKER").location == NSNotFound,
                "\(label): MARKER must not survive in the output under a search-sourced region on a rotated, offset-CropBox page")
    }

    // --- D08-F3: search-sourced region → export → MARKER destroyed under the
    //     region, across CropBox origins (offset-CropBox end-to-end guard;
    //     couples to D01-F2 / D08-F1). On a zero-origin page boundingRect is a
    //     no-op; on an offset page the missing -pageBounds.origin subtraction
    //     displaces the fill → MARKER survives. Asserts TERM-ABSENCE, not Layer-2
    //     status, because the .searchableRedaction → .info continuity (CAT-351)
    //     masks a leak. Permanent red without D01-F2; red→green proves the fix. ---
    @Test("Search-sourced region destroys MARKER under the region across CropBox origins",
          arguments: [CGPoint.zero, CGPoint(x: 50, y: 50)])
    func searchSourcedRegionDestroysMarkerOnOffsetCropBox(origin: CGPoint) async throws {
        let data = TestFixtures.rotatedTextPDF(rotation: 0, cropBoxOrigin: origin)
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let label = "origin=(\(Int(origin.x)),\(Int(origin.y)))"

        let text = try #require(page.string) as NSString
        let range = text.range(of: "MARKER")
        #expect(range.location != NSNotFound, "\(label): fixture must contain MARKER")
        let regionRect = try #require(
            DocumentSearcher().boundingRect(for: range, page: page),
            "\(label): boundingRect must produce a region for MARKER")
        let region = RedactionRegion(id: UUID(), normalizedRect: regionRect, source: .manual)

        let outURL = try await TestPipeline.processAndExport(
            data, mode: .searchableRedaction, regions: [0: [region]]
        )
        defer { try? FileManager.default.removeItem(at: outURL) }
        let outDoc = try #require(PDFDocument(url: outURL))
        let outPage = try #require(outDoc.page(at: 0))

        // Positive leak assertion: the term must be GONE from the output's
        // selectable text under a correctly placed search region. On the offset
        // case with the pre-D01-F2 producer, the fill misses MARKER → it survives.
        let outString = (outPage.string ?? "") as NSString
        #expect(outString.range(of: "MARKER").location == NSNotFound,
                "\(label): MARKER must not survive in the output under a search-sourced region")
    }
}
