import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import RedactionCore
@testable import RedactionEngine

// A Search box as the record carries it: placed from the page's typed text,
// still anchored, with no selected characters. At the switch's policy, with
// the switch on and the page's words read, its cover is at least what "as
// placed" paints today, growth included. Each box is cut short of its ink,
// as when a user drags a box's edge back through a letter: one over the left
// of a bar that runs on past its edge, one over the start of a typed word.

@Suite("A Search box with no selection keeps today's cover")
struct SearchBoxNoSelectionCoverTests {
    typealias S = PlanSwitchTests

    /// The bar's left 18 pt of 30, and "Ordinary"'s first letters.
    static let shares = [CGRect(x: 36, y: 38, width: 22, height: 12), CGRect(x: 8, y: 96, width: 22, height: 16)]

    struct Painted {
        let bitmap: PlanPaintTests.Bitmap
        let plan: PaintPlan?
    }

    /// The two regions: anchored to the text they were placed from, or the
    /// same regions after the user dragged an edge (placed from the text,
    /// no longer anchored).
    static func regions(edited: Bool) -> [RedactionRegion] {
        Self.shares.map {
            var region = RedactionRegion(id: UUID(), normalizedRect: S.share($0), source: .searchMatch(term: "x"),
                                         textAnchored: true)
            if edited { region.textAnchored = false }
            return region
        }
    }

    static func paint(source: PlanSource, read: Bool, mode: PipelineMode, edited: Bool) async throws -> Painted {
        let doc = try #require(PDFDocument(data: S.pdf()))
        defer { withExtendedLifetime(doc) {} }
        let page = try #require(doc.page(at: 0))
        let regions = Self.regions(edited: edited)
        let drawn = regions.map(RunRecord.DrawnRegion.init(region:))
        #expect(drawn.allSatisfy { $0.kind == (edited ? .placedFromTextThenEdited : .placedFromTextAnchored) })
        let pageRead = read ? try await RunRecordPageReadTests.read(S.pdf()) : nil
        let confirmed = RunRecord.Page(pageIndex: 0, regions: drawn, cropBox: page.bounds(for: .cropBox).size,
                                       rotation: page.rotation, switchOn: true, read: pageRead, source: source)
        var data = PDFPageData(
            page: page, pageIndex: 0, regions: regions, fillColor: .black, targetDPI: S.dpi,
            pipelineMode: mode, rotation: page.rotation,
            cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef,
            hasText: page.string?.isEmpty == false, confirmedPage: confirmed)
        data.planSource = source
        let result = try await PageRasterizer().rasterize(data, dpiCap: S.dpi)
        return Painted(bitmap: try PlanPaintTests.Bitmap(result.pageOutput.image), plan: confirmed.plan)
    }

    /// The black pixels of a bitmap.
    static func black(_ b: PlanPaintTests.Bitmap) -> Set<Int> {
        var out: Set<Int> = []
        for y in 0..<b.height { for x in 0..<b.width where b.pixel(x, y, is: 0) { out.insert(y * b.width + x) } }
        return out
    }

    @Test("At the switch, with the page's words, an anchored Search box and one whose edge was dragged each cover every pixel \"as placed\" paints, growth included",
          arguments: [PipelineMode.secureRasterization, .searchableRedaction], [false, true])
    func coverHoldsTodaysPaint(mode: PipelineMode, edited: Bool) async throws {
        let today = try await Self.paint(source: .asPlaced, read: false, mode: mode, edited: edited)
        let head = try await Self.paint(source: .switchPolicy, read: true, mode: mode, edited: edited)
        let before = Self.black(today.bitmap), after = Self.black(head.bitmap)
        #expect(before.subtracting(after).isEmpty, "\(before.subtracting(after).count) pixels painted today and not at the switch")
        // The case means something: today's paint reaches past the bar box's
        // own rectangle (growth over the bar's ink).
        let bar = S.pixels(Self.shares[0])
        let past = before.filter { i in
            let x = i % today.bitmap.width, y = i / today.bitmap.width
            return x >= bar.maxX && y >= bar.minY && y < bar.maxY
        }
        #expect(!past.isEmpty, "today's growth paints the bar past the box's edge")
        // Neither box is judged. The anchored box reads as scan or picture
        // (no selection), so the switch could not widen it; the dragged box
        // paints as drawn.
        let plan = try #require(head.plan)
        #expect(plan.boxes.count == 2)
        for box in plan.boxes {
            #expect(!box.inkCheckable)
            if edited {
                #expect(box.asDrawn)
            } else if case .couldNotWiden = box.treatment {} else { Issue.record("treatment \(box.treatment)") }
        }
    }
}
