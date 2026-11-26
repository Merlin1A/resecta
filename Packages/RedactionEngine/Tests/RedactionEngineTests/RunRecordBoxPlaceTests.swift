import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import RedactionEngine

// The run's box-place check (`RunRecord+BoxPlace.swift`): the frame it reads a
// box back through, the probe's two shares, and the rule that refuses a page.
// The canvas's own maps are not used here: every expected place is written
// out by hand from the rotation's definition (a page with /Rotate r is shown
// turned r degrees clockwise).

@Suite("Run record: the box-place check")
struct RunRecordBoxPlaceTests {

    static let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let offset = CGRect(x: 36, y: 54, width: 540, height: 684)
    /// A4's sides are not whole points.
    static let a4 = CGRect(x: 0, y: 0, width: 595.276, height: 841.89)
    /// A crop box with a fractional origin and sides.
    static let fractional = CGRect(x: 12.345, y: 67.891, width: 401.123, height: 577.777)
    static let crops = [letter, offset, a4, fractional]
    static let turns = [0, 90, 180, 270]

    static func near(_ a: CGPoint, _ b: CGPoint) -> Bool { RunRecord.axisGap(a, b) < 1e-9 }

    @Test("The crop box's bottom-left corner is shown where the turn puts it", arguments: turns)
    func cornerByHand(rotation: Int) {
        // Clockwise: 90 takes the bottom-left corner to the top-left, 180 to
        // the top-right, 270 to the bottom-right.
        let expected: [Int: CGPoint] = [0: CGPoint(x: 0, y: 0), 90: CGPoint(x: 0, y: 1),
                                        180: CGPoint(x: 1, y: 1), 270: CGPoint(x: 1, y: 0)]
        for crop in Self.crops {
            let geometry = RunRecord.PageGeometry(cropBox: crop, rotation: rotation)
            let corner = geometry.displayedShare(ofPagePoint: CGPoint(x: crop.minX, y: crop.minY))
            #expect(Self.near(corner, expected[rotation]!), "\(rotation)° over \(crop): \(corner)")
            // The bottom-right corner: clockwise, 90 takes it to the bottom-left,
            // 180 to the top-left, 270 to the top-right.
            let right = geometry.displayedShare(ofPagePoint: CGPoint(x: crop.maxX, y: crop.minY))
            let expectedRight: [Int: CGPoint] = [0: CGPoint(x: 1, y: 0), 90: CGPoint(x: 0, y: 0),
                                                 180: CGPoint(x: 0, y: 1), 270: CGPoint(x: 1, y: 1)]
            #expect(Self.near(right, expectedRight[rotation]!), "\(rotation)° over \(crop): \(right)")
        }
    }

    @Test("Page point and shown share are each other's inverse, for points and rectangles",
          arguments: [0, 90, 180, 270, -90, 450])
    func roundTrips(rotation: Int) {
        for crop in Self.crops {
            let geometry = RunRecord.PageGeometry(cropBox: crop, rotation: rotation)
            for share in [CGPoint(x: 0.2, y: 0.6), CGPoint(x: 0.9, y: 0.15), CGPoint(x: -0.1, y: 1.2)] {
                let back = geometry.displayedShare(ofPagePoint: geometry.pagePoint(ofDisplayedShare: share))
                #expect(Self.near(back, share), "\(rotation)° over \(crop): \(share) came back \(back)")
            }
            let box = CGRect(x: 0.18, y: 0.62, width: 0.22, height: 0.03)
            let onPage = geometry.pageRect(ofDisplayedShare: box)
            #expect(RunRecord.sideGap(geometry.displayedShare(ofPageRect: onPage), box) < 1e-9)
            // The rectangle's corners are the points' images.
            let corner = geometry.pagePoint(ofDisplayedShare: CGPoint(x: box.minX, y: box.minY))
            #expect(onPage.contains(corner) || abs(onPage.minX - corner.x) < 1e-9 || abs(onPage.maxX - corner.x) < 1e-9)
        }
    }

    @Test("No turn or flip of the page fixes both probe shares: each moves one by at least 0.2")
    func probeSharesHaveNoSymmetry() {
        let symmetries: [(String, (CGPoint) -> CGPoint)] = [
            ("90", { CGPoint(x: $0.y, y: 1 - $0.x) }), ("180", { CGPoint(x: 1 - $0.x, y: 1 - $0.y) }),
            ("270", { CGPoint(x: 1 - $0.y, y: $0.x) }), ("mirror x", { CGPoint(x: 1 - $0.x, y: $0.y) }),
            ("mirror y", { CGPoint(x: $0.x, y: 1 - $0.y) }), ("diagonal", { CGPoint(x: $0.y, y: $0.x) }),
            ("anti-diagonal", { CGPoint(x: 1 - $0.y, y: 1 - $0.x) }),
        ]
        #expect(RunRecord.boxPlaceProbeShares.count == 2)
        var least = CGFloat.infinity
        for (name, map) in symmetries {
            let moved = RunRecord.boxPlaceProbeShares.map { RunRecord.axisGap(map($0), $0) }.max()!
            #expect(moved >= 0.2 - 1e-12, "\(name) moves the pair by only \(moved)")
            least = min(least, moved)
        }
        #expect(abs(least - 0.2) < 1e-12, "the anti-diagonal is the least, at 0.2 of a side")
    }

    /// A one-page file with `crop` as its crop box and `rotation` as its
    /// /Rotate, written and read back so CoreGraphics' page carries both.
    static func page(crop: CGRect, rotation: Int) throws -> (PDFPage, CGPDFPage) {
        let data = NSMutableData()
        // A media box that holds every crop here (A4 is taller than Letter).
        var media = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let document = try #require(PDFDocument(data: data as Data))
        let first = try #require(document.page(at: 0))
        first.setBounds(crop, for: .cropBox)
        first.rotation = rotation
        let written = try #require(document.dataRepresentation())
        let page = try #require(PDFDocument(data: written)?.page(at: 0))
        return (page, try #require(page.pageRef))
    }

    @Test("Where the run's frame puts a box on the page is where the painter's own transform paints it",
          arguments: turns)
    func frameMatchesThePainter(rotation: Int) throws {
        for crop in Self.crops {
            let (page, cgPage) = try Self.page(crop: crop, rotation: rotation)
            // Written and read back, the crop box keeps its place to a
            // thousandth of a point (the file writes its numbers rounded).
            #expect(page.rotation == rotation)
            #expect(RunRecord.sideGap(page.bounds(for: .cropBox), crop) < 0.001,
                    "\(crop) read back as \(page.bounds(for: .cropBox))")
            let geometry = RunRecord.PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
            let size = geometry.frame.displayedSize
            let target = CGRect(origin: .zero, size: size)
            let transform = PageRasterizer.drawingTransform(
                for: cgPage, box: .cropBox, rotation: page.rotation, targetRect: target)
            for share in [Self.share, CGRect(x: 0.71, y: 0.08, width: 0.2, height: 0.31)] {
                let painted = geometry.pageRect(ofDisplayedShare: share).applying(transform)
                let expected = CGRect(x: share.minX * size.width, y: share.minY * size.height,
                                      width: share.width * size.width, height: share.height * size.height)
                #expect(RunRecord.sideGap(painted, expected) < 1e-6,
                        "\(rotation)° over \(crop): the frame's place \(painted), the painter's \(expected)")
            }
        }
    }

    // MARK: - The rule

    static let geometry = RunRecord.PageGeometry(cropBox: offset, rotation: 90)
    static let share = CGRect(x: 0.18, y: 0.62, width: 0.22, height: 0.03)

    static func page(_ regions: [RunRecord.DrawnRegion], geometry: RunRecord.PageGeometry? = geometry,
                     atStore: RunRecord.PageGeometry? = geometry, index: Int = 0) -> RunRecord.Page {
        guard let geometry else { return RunRecord.Page(pageIndex: index, regions: regions) }
        return RunRecord.Page(pageIndex: index, regions: regions, geometry: geometry, geometryAtStore: atStore, switchOn: false)
    }

    static func drawn(_ share: CGRect = share, shiftedBy dx: CGFloat = 0) -> RunRecord.DrawnRegion {
        RunRecord.DrawnRegion(id: UUID(), normalizedRect: share, kind: .drawnByHand,
                              drawnPageRect: geometry.pageRect(ofDisplayedShare: share).offsetBy(dx: dx, dy: 0))
    }

    @Test("A box drawn where its share is stored, by the run's frame, is confirmed")
    func confirmedAtTheFix() {
        #expect(Self.page([Self.drawn()]).boxPlacesConfirmed(canvasFailed: false))
        // Read unclamped: a box drawn past the page's edge is compared as drawn.
        let past = CGRect(x: -0.1, y: 0.4, width: 0.3, height: 0.05)
        #expect(Self.page([Self.drawn(past)]).boxPlacesConfirmed(canvasFailed: false))
        // A box no gesture placed (found, duplicated, stepped) is left to the canvas probe.
        #expect(Self.page([RunRecord.DrawnRegion(id: UUID(), normalizedRect: Self.share, kind: .drawnByHand)])
            .boxPlacesConfirmed(canvasFailed: false))
        #expect(Self.page([]).boxPlacesConfirmed(canvasFailed: true), "a page with no box is never refused")
    }

    @Test("A box stored off its drawn place by more than 0.01 pt is refused; within it, confirmed")
    func storedOffItsDrawnPlace() {
        #expect(!Self.page([Self.drawn(shiftedBy: 0.05)]).boxPlacesConfirmed(canvasFailed: false))
        #expect(!Self.page([Self.drawn(shiftedBy: -0.011)]).boxPlacesConfirmed(canvasFailed: false))
        #expect(Self.page([Self.drawn(shiftedBy: 0.005)]).boxPlacesConfirmed(canvasFailed: false))
        // A share stored in the page's stored frame (turned back) beside a correct drawn place.
        let storedFrame = CGRect(x: 1 - Self.share.maxY, y: Self.share.minX,
                                 width: Self.share.height, height: Self.share.width)
        let planted = RunRecord.DrawnRegion(id: UUID(), normalizedRect: storedFrame, kind: .drawnByHand,
                                            drawnPageRect: Self.geometry.pageRect(ofDisplayedShare: Self.share))
        #expect(!Self.page([Self.drawn(), planted]).boxPlacesConfirmed(canvasFailed: false))
    }

    @Test("A page whose canvas failed the probe, or whose geometry is unread or changed since its boxes were stored, is refused")
    func refusedPages() {
        #expect(!Self.page([Self.drawn()]).boxPlacesConfirmed(canvasFailed: true))
        #expect(!Self.page([Self.drawn()], geometry: nil).boxPlacesConfirmed(canvasFailed: false))
        #expect(!Self.page([Self.drawn()], atStore: nil).boxPlacesConfirmed(canvasFailed: false),
                "no geometry noted at store")
        let turned = RunRecord.PageGeometry(cropBox: Self.offset, rotation: 180)
        #expect(!Self.page([Self.drawn()], atStore: turned).boxPlacesConfirmed(canvasFailed: false))
        let cropped = RunRecord.PageGeometry(cropBox: Self.offset.insetBy(dx: 1, dy: 0), rotation: 90)
        #expect(!Self.page([Self.drawn()], atStore: cropped).boxPlacesConfirmed(canvasFailed: false))
        // A rotation noted unnormalized is the same rotation.
        let same = RunRecord.PageGeometry(cropBox: Self.offset, rotation: 450)
        #expect(Self.page([Self.drawn()], atStore: same).boxPlacesConfirmed(canvasFailed: false))
    }

    @Test("The run names the first page, in page order, whose boxes are not confirmed")
    func firstRefusedPage() {
        let pages = [Self.page([Self.drawn()], index: 0), Self.page([], index: 1),
                     Self.page([Self.drawn(shiftedBy: 1)], index: 2), Self.page([Self.drawn()], index: 3)]
        let record = RunRecord.Confirmed(fillColor: .black, exportDPI: 300, pages: pages)
        #expect(record.firstPageWithUnconfirmedBoxPlace(canvasFailures: []) == 2)
        #expect(record.firstPageWithUnconfirmedBoxPlace(canvasFailures: [1]) == 2, "page 2 has no box")
        #expect(record.firstPageWithUnconfirmedBoxPlace(canvasFailures: [0]) == 0)
        let fixed = RunRecord.Confirmed(fillColor: .black, exportDPI: 300,
                                        pages: [pages[0], pages[1], pages[3]])
        #expect(fixed.firstPageWithUnconfirmedBoxPlace(canvasFailures: []) == nil)
    }

    @Test("The record's page made with geometry has the same plan as one made from its sides")
    func samePlan() {
        let regions = [Self.drawn()]
        let bySides = RunRecord.Page(pageIndex: 0, regions: regions, cropBox: Self.offset.size, rotation: 90, switchOn: false)
        #expect(Self.page(regions).plan == bySides.plan)
        #expect(Self.page(regions).plan != nil)
    }

    @Test("The refusal's description names the page and says it was not redacted")
    func refusalDescription() {
        #expect(PipelineError.redactionError(.boxPlaceUnconfirmed(pageIndex: 2)).errorDescription
            == "A box on page 3 could not be confirmed where it was drawn. The page was not redacted.")
    }
}
