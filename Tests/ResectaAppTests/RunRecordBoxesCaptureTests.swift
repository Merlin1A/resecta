import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// The capture's half of the run's record of boxes: the record is made once at
// run entry and each page's data carries that page of the record to the
// producer. The record's own boxes are tested in the engine's
// RunRecordBoxesTests; what those boxes are is not readable here.

@Suite("The run's record: the capture carries it")
@MainActor
struct RunRecordBoxesCaptureTests {

    private func settings() -> PipelineCoordinator.RunSettings {
        let name = "run-record-boxes-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let snapshot = PipelineCoordinator.RunSettings.snapshot(from: SettingsState(defaults: defaults))
        defaults.removePersistentDomain(forName: name)
        return snapshot
    }

    private static func region(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: CGRect(x: x, y: y, width: w, height: h), source: .manual)
    }

    /// Regions of every kind: inside, past the right edge, 0.0005 high, and of
    /// full size wholly off the right, the top, the left and the bottom; a
    /// page with none.
    private static func regions() -> [Int: [RedactionRegion]] {
        [0: [region(0.1, 0.1, 0.2, 0.1), region(0.9, 0.5, 0.2, 0.05), region(0.3, 0.3, 0.2, 0.0005)],
         1: [region(1.2, 0.2, 0.3, 0.2), region(0.2, 1.2, 0.3, 0.2), region(-0.5, 0.2, 0.3, 0.2),
             region(0.2, -0.5, 0.3, 0.2)]]
    }

    private func capture() -> (record: RunRecord.Confirmed, pages: [PDFPageData]) {
        let doc = makeMultiPagePDFDocument(pages: 3)
        let regions = Self.regions()
        let snapshot = settings()
        let record = RunInputs.confirmedRecord(
            pageCount: doc.pageCount, geometry: RunInputs.pageGeometry(of: doc),
            regions: regions, settings: snapshot)
        let pages = RunInputs.pageData(
            document: doc, regions: regions, textLayerStatus: [0: .rich, 1: .rich, 2: .rich],
            sourceHasHiddenOCG: false, settings: snapshot, effectiveMode: .secureRasterization, record: record)
        return (record, pages)
    }

    @Test("On every page, the page data holds exactly the record's regions that admission lets through")
    func regionsAreTheAdmitted() {
        let (record, pages) = capture()
        #expect(pages.count == 3)
        for page in pages {
            let confirmed = record.pages.first { $0.pageIndex == page.pageIndex }
            let admitted = (confirmed?.regions ?? []).filter { RedactionRegion.isAdmitted(normalizedRect: $0.normalizedRect) }
            #expect(page.regions.map(\.id) == admitted.map(\.id), "page \(page.pageIndex)")
        }
        // Admission cuts a region to the page on all four sides: the four
        // regions wholly off the page on page 1 are refused, off the left and
        // the bottom as well as off the right and the top.
        #expect(pages.map { $0.regions.count } == [2, 0, 0])
    }

    @Test("On every page, the admitted and the refused are together the regions as drawn, and none is both")
    func admittedAndRefusedAreTheDrawn() {
        let (record, pages) = capture()
        let drawn = Self.regions()
        for page in pages {
            let confirmed = record.pages.first { $0.pageIndex == page.pageIndex }
            let admitted = Set(page.regions.map(\.id))
            let refused = Set((confirmed?.refusedRegions ?? []).map(\.id))
            #expect(admitted.isDisjoint(with: refused), "page \(page.pageIndex)")
            #expect(admitted.union(refused) == Set((drawn[page.pageIndex] ?? []).map(\.id)), "page \(page.pageIndex)")
        }
        #expect(record.pages[1].refusedRegions.map(\.reason) == Array(repeating: .offThePage, count: 4))
        #expect(record.pages[0].refusedRegions.map(\.reason) == [.tooThinToPaint])
    }

    @Test("The app's readers of admission give the predicate's answer")
    func appSitesGiveOneAnswer() {
        let state = RedactionState()
        let refusedOnly = (Self.regions()[1] ?? []) + [Self.region(0.3, 0.3, 0.2, 0.0005)]
        state.regions[0] = refusedOnly
        #expect(refusedOnly.allSatisfy { !RedactionRegion.isAdmitted(normalizedRect: $0.normalizedRect) })
        #expect(!state.hasEffectiveRegions, "no region a run admits: nothing to redact")
        state.regions[0] = refusedOnly + [Self.region(-0.15, 0.4, 0.3, 0.05)]
        #expect(state.hasEffectiveRegions, "a region half off the left is admitted on its on-page half")
    }

    @Test("On every page, the page data carries the record's page, its boxes and two sides with it")
    func pageDataCarriesTheRecord() throws {
        let (record, pages) = capture()
        #expect(record.pages.count == 3)
        for page in pages {
            let carried = try #require(page.confirmedPage, "page \(page.pageIndex)")
            #expect(carried == record.pages[page.pageIndex], "page \(page.pageIndex)")
            // A page with no plan equals one made without its sides: so the
            // carried page differs from that one only when it has its plan.
            #expect(carried != RunRecord.Page(pageIndex: carried.pageIndex, regions: carried.regions),
                    "page \(page.pageIndex) has its plan")
        }
    }
}
