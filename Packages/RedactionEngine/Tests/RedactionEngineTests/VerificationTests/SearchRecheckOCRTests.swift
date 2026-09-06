import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// The Search Re-check on image-only output — the searcher's own OCR path
// (`.accurate`, 300 DPI) is the route. Vision-backed, simulator-only like
// the Layer-2 OCR suites; every value is public fixture vocabulary.

@Suite("Search Re-check (OCR route)", .serialized)
struct SearchRecheckOCRTests {

    @Test("A rendered-text page with no text layer is read by OCR; the route says so")
    func ocrRouteOnRenderedText() async throws {
        let img = try TestFixtures.renderedTextImage("CONFIDENTIAL", width: 1200, height: 1500, fontSize: 130)
        let (doc, url) = try await TestFixtures.imagePagesPDF([img], size: CGSize(width: 1200, height: 1500))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect((doc.page(at: 0)?.string ?? "").isEmpty, "the fixture must carry no text layer")

        // R-1 (raster half): the sub-document keeps the page image.
        let data = try #require(doc.page(at: 0)?.dataRepresentation)
        let sub = try #require(PDFDocument(data: data))
        let thumb = sub.page(at: 0)?.thumbnail(of: CGSize(width: 300, height: 375), for: .cropBox)
        #expect(thumb?.cgImage != nil, "the raster must survive dataRepresentation → PDFDocument(data:)")

        let survivor = await TestFixtures.recheck(
            SendablePDFDocument(doc), requests: [TestFixtures.textRequest("CONFIDENTIAL")],
            mode: .secureRasterization)
        #expect(survivor.status == .attention(""), "OCR must locate the rendered word; got \(survivor.status)")
        #expect(survivor.queryLines?.first?.route == .ocr)
        #expect(survivor.queryLines?.first?.remainingCount ?? 0 >= 1)
        #expect(survivor.detailDescription.contains("Text was read by OCR from the rendered pages."))

        let clean = await TestFixtures.recheck(
            SendablePDFDocument(doc), requests: [TestFixtures.textRequest("Delia")],
            mode: .secureRasterization)
        #expect(clean.status == .pass, "a word the page does not carry → PASS; got \(clean.status)")
        #expect(clean.queryLines?.first?.route == .ocr)
        #expect(clean.detailDescription == "\(SearchRecheck.detailLead) Text was read by OCR from the rendered pages.")
    }

    @Test("A page over the OCR pixel cap is reported 'too large to scan for text', not read as clear")
    func oversizePageIsReported() async throws {
        // 300-DPI render of a 40×40-inch page = 12000 px per axis > the searcher's cap.
        let size = CGSize(width: 40 * 72, height: 40 * 72)
        let img = try TestFixtures.renderedTextImage("CONFIDENTIAL", width: 1600, height: 1600, fontSize: 160)
        let (doc, url) = try await TestFixtures.imagePagesPDF([img], size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await TestFixtures.recheck(
            SendablePDFDocument(doc), requests: [TestFixtures.textRequest("CONFIDENTIAL")],
            mode: .secureRasterization)
        #expect(result.status == .warn(""), "an unreadable page must not PASS; got \(result.status)")
        #expect(TestFixtures.message(of: result.status)
                == "Re-ran 1 search; 1 page could not be checked: 1 (too large to scan for text)")
        #expect(result.pageReferences == [0])
    }

    @Test("Cancellation mid-run surrenders as skipped")
    func cancellationIsSkipped() async throws {
        var images: [CGImage] = []
        for _ in 0..<4 {
            images.append(try TestFixtures.renderedTextImage("CONFIDENTIAL", width: 1200, height: 1500, fontSize: 130))
        }
        let (doc, url) = try await TestFixtures.imagePagesPDF(images, size: CGSize(width: 1200, height: 1500))
        defer { try? FileManager.default.removeItem(at: url) }
        let wrapped = SendablePDFDocument(doc)
        let task = Task {
            await TestFixtures.recheck(
                wrapped, requests: [TestFixtures.textRequest("CONFIDENTIAL")], mode: .secureRasterization)
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.value
        #expect(result.status == .skipped, "a cancelled re-check must report skipped; got \(result.status)")
        #expect(result.shortDescription == "Skipped.")
    }

    @Test("Corpus leg: a ground-truth name on the scanned packet is found on at least its listed pages")
    func scannedPacketRecallFloor() async throws {
        guard let pdfURL = Bundle.module.url(
                forResource: "packet-scan-sim-150dpi", withExtension: "pdf", subdirectory: "TestResources"),
              let gtURL = Bundle.module.url(
                forResource: "packet-ground-truth", withExtension: "json", subdirectory: "TestResources")
        else { throw TestFixtures.RecheckFixtureError.failed }
        let doc = try #require(PDFDocument(url: pdfURL))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: gtURL)) as? [String: Any])
        let occurrences = try #require(json["occurrences"] as? [[String: Any]])
        // The ground truth lists this ACH-descriptor form on two scanned pages
        // with OCR applicability (pages 3 and 11, 1-based); the default search
        // is case-insensitive, so any other case form only widens the page set.
        let value = "MATEO HARTWELL"
        let listedPages = Set(occurrences.compactMap { occ -> Int? in
            guard occ["value"] as? String == value,
                  (occ["leg_applicability"] as? [String])?.contains("ocr") == true,
                  occ["expectation"] as? String == "should_fire" else { return nil }
            return occ["page"] as? Int
        })
        try #require(listedPages.count >= 2, "the fixture must list the value on at least two pages")

        let result = await TestFixtures.recheck(
            SendablePDFDocument(doc), requests: [TestFixtures.textRequest(value)],
            mode: .secureRasterization)
        #expect(result.status == .attention(""), "the value survives on the unredacted scan; got \(result.status)")
        let pages = Set(result.pageReferences ?? [])
        print("SV-corpus [\(value)] ground-truth OCR pages=\(listedPages.sorted()) re-check pages=\(pages.sorted()) remaining=\(result.queryLines?.first?.remainingCount ?? -1)")
        #expect(pages.count >= listedPages.count,
                "recall floor: remaining-match pages \(pages.sorted()) must cover at least the \(listedPages.count) listed pages")
        #expect(listedPages.isSubset(of: pages), "every listed page must carry a remaining match")
    }
}
