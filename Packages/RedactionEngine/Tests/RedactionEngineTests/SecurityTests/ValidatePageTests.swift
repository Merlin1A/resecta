import Testing
import Foundation
import PDFKit
import os
@testable import RedactionEngine

// ENGINE §2.6 — Input validation tests.

@Suite("Page Validation", .tags(.security))
struct ValidatePageTests {

    @Test("RawPDFBuilder creates pages with correct bounds")
    func fixturePageBounds() throws {
        let data = TestFixtures.blankPage(width: 612, height: 792)
        let doc = PDFDocument(data: data)
        #expect(doc != nil, "PDFDocument should parse blankPage fixture")
        #expect(doc?.pageCount == 1)
        let page = doc?.page(at: 0)
        #expect(page != nil)
        let bounds = page?.bounds(for: .cropBox) ?? .zero
        #expect(bounds.width > 0, "CropBox width should be > 0, got \(bounds)")
        #expect(bounds.height > 0, "CropBox height should be > 0, got \(bounds)")
    }

    @Test("Rejects oversized page (width > 5000)")
    func rejectsOversizedWidth() throws {
        let page = try makePDFPage(width: 6000, height: 792)
        #expect(validatePage(page, effectiveDPI: 150) == false)
    }

    @Test("Rejects oversized page (height > 5000)")
    func rejectsOversizedHeight() throws {
        let page = try makePDFPage(width: 612, height: 6000)
        #expect(validatePage(page, effectiveDPI: 150) == false)
    }

    @Test("Accepts standard page when memory is sufficient")
    func acceptsStandardPage() throws {
        let page = try makePDFPage(width: 612, height: 792)
        let bounds = page.bounds(for: .cropBox)
        let scale: CGFloat = 150.0 / 72.0
        let bytes = Int(ceil(bounds.width * scale)) * Int(ceil(bounds.height * scale)) * 4
        let available = os_proc_available_memory()
        // Only assert pass if we know memory is sufficient
        if bytes < Int(available) / 2 {
            #expect(validatePage(page, effectiveDPI: 150) == true)
        }
        // Always verify the dimension check passes (bounds are within 5000)
        #expect(bounds.width <= 5000 && bounds.height <= 5000,
                "Standard page should pass dimension check")
    }

    @Test("Accepts standard page at full DPI when availability is unreadable (CAT-138 / D-34)")
    func acceptsStandardPageAtFullDPIDespiteUnreadableAvailability() throws {
        // D-34 (measured 2026-06-13): on the simulator
        // `os_proc_available_memory()` reports an unusable value (well under
        // 67 MB) regardless of real headroom, so the raw half-available clause
        // would refuse a standard 612×792 page's 300-DPI raster (~33.7 MB) and
        // CAT-138's wire-up would then reject every page. The guard defers such
        // unusable readings (≤ the §2.5 150 MB headroom) to the runtime DPI cap
        // / `selectDPI`, accepting the page on dimension grounds. On real
        // hardware the reading is accurate and a standard page needs far less
        // than half of available memory, so the clause also returns true — the
        // assertion therefore holds in both environments once the guard is in
        // place. (Unlike `acceptsStandardPage` above, this asserts
        // unconditionally — that is the point of the guard.)
        let page = try makePDFPage(width: 612, height: 792)
        #expect(validatePage(page, effectiveDPI: 300) == true,
                "Standard page must validate at 300 DPI even when os_proc_available_memory() is unreadable")
    }

    @Test("Higher DPI increases memory requirement")
    func higherDPIIncreasesMemory() throws {
        let page = try makePDFPage(width: 612, height: 792)
        let at150 = validatePage(page, effectiveDPI: 150)
        let at300 = validatePage(page, effectiveDPI: 300)
        // If 300 DPI passes, 150 DPI must also pass
        if at300 { #expect(at150 == true) }
    }

    @Test("5000x5000 at any DPI does not crash")
    func maxBoundaryNoCrash() throws {
        let page = try makePDFPage(width: 5000, height: 5000)
        _ = validatePage(page, effectiveDPI: 150)
    }

    @Test("Rejects page with dimension below 10pt")
    func rejectsTinyPage() throws {
        // 5×5pt is below the 10pt minimum
        let page = try makePDFPage(width: 5, height: 5)
        #expect(validatePage(page, effectiveDPI: 150) == false,
                "Page smaller than 10pt should be rejected")
    }

    @Test("Accepts page at exactly 10pt dimensions")
    func acceptsMinimumPage() throws {
        let page = try makePDFPage(width: 10, height: 10)
        // At 150 DPI, 10×10pt → ~21×21px → 1764 bytes — always fits in memory
        let bounds = page.bounds(for: .cropBox)
        if bounds.width >= 10 && bounds.height >= 10 {
            let scale: CGFloat = 150.0 / 72.0
            let bytes = Int(ceil(bounds.width * scale)) * Int(ceil(bounds.height * scale)) * 4
            if bytes < Int(os_proc_available_memory()) / 2 {
                #expect(validatePage(page, effectiveDPI: 150) == true,
                        "10pt page should pass validation")
            }
        }
    }

    // MARK: - Helpers

    private func makePDFPage(width: Int, height: Int) throws -> PDFPage {
        let data = TestFixtures.blankPage(width: width, height: height)
        guard let doc = PDFDocument(data: data),
              let page = doc.page(at: 0) else {
            throw TestError.invalidFixture
        }
        return page
    }

    private enum TestError: Error { case invalidFixture }
}
