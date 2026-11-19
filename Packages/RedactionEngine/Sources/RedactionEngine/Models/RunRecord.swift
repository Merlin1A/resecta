import CoreGraphics
import Foundation

/// The record of one run, kept beside its export: what the user confirmed
/// when they tapped Redact, and what the producer says it did.
///
/// What is checked after an export is taken from the first part. The second
/// part is only ever compared against; it never decides what is checked, and
/// the producer never reads it back. The record is a value in memory only:
/// it is not encodable, and it is kept in the run inputs that sit beside the
/// output and are cleared with it. An export with no record cannot have its
/// boxes checked.
public struct RunRecord: Equatable, Sendable {
    /// What the user confirmed at the Redact tap. Written once; never changed.
    public let confirmed: Confirmed
    /// What the producer says it did, written as the run goes.
    public let produced: Produced

    /// The record of a run: the confirmed part, built at run entry, joined
    /// once to the part the run produced.
    public init(confirmed: Confirmed, produced: Produced) {
        self.confirmed = confirmed
        self.produced = produced
    }

    // MARK: - Part 1: what the user confirmed

    /// The settings and the regions the run was started with.
    public struct Confirmed: Equatable, Sendable {
        /// The fill colour a box is painted with.
        public let fillColor: FillColor
        /// The quality chosen: the dots per inch a page image is made at.
        public let exportDPI: Int
        /// One entry per page of the document, in page order, a page with
        /// no region too.
        public let pages: [Page]

        public init(fillColor: FillColor, exportDPI: Int, pages: [Page]) {
            self.fillColor = fillColor
            self.exportDPI = exportDPI
            self.pages = pages
        }
    }

    /// One page as the user confirmed it.
    public struct Page: Equatable, Sendable {
        /// The page's place in the document, from 0.
        public let pageIndex: Int
        /// Every region on the page as it was drawn, before the clamp to the
        /// page and before the size floor: a region the run drops is still
        /// here.
        public let regions: [DrawnRegion]
        /// The page's two sides in whole sixty-fourths of a point and the
        /// boxes of its plan, made once at run entry. Nil until the run
        /// entry makes them.
        package let plan: PaintPlan?

        /// The page's regions that admission refuses, each with its reason,
        /// in the order they were drawn. Given by the regions as drawn, so it
        /// is never stored: every region is here or reaches the run, and none
        /// vanishes. Read it from the run's record, never from the editor's
        /// regions as they stand later.
        public var refusedRegions: [(id: UUID, reason: RegionAdmission.Refusal)] {
            regions.compactMap { region in
                RedactionRegion.admission(normalizedRect: region.normalizedRect).map { (region.id, $0) }
            }
        }

        public init(pageIndex: Int, regions: [DrawnRegion]) {
            self.init(pageIndex: pageIndex, regions: regions, plan: nil)
        }

        /// One page as confirmed, with its plan made at run entry from the
        /// page's crop box and rotation. The page's two sides S are read in
        /// the frame as the page is rasterised, so a page turned a quarter
        /// has its sides swapped. The plan holds one box for each region
        /// admission lets through, as placed. The plan is nil when a side
        /// cannot be read.
        public init(pageIndex: Int, regions: [DrawnRegion], cropBox: CGSize, rotation: Int) {
            let turned = ((rotation % 360) + 360) % 180 != 0
            var plan: PaintPlan?
            if let width = PixelPlan.sixtyFourths(ofSide: Double(turned ? cropBox.height : cropBox.width)),
               let height = PixelPlan.sixtyFourths(ofSide: Double(turned ? cropBox.width : cropBox.height)) {
                let admitted = regions.filter { RedactionRegion.isAdmitted(normalizedRect: $0.normalizedRect) }
                plan = PaintPlan.asPlaced(
                    regions: admitted.map { region in
                        let r = region.normalizedRect
                        return (region.id, PointRect(minX: Double(r.minX), minY: Double(r.minY),
                                                     maxX: Double(r.maxX), maxY: Double(r.maxY)))
                    },
                    widthSixtyFourths: width, heightSixtyFourths: height)
            }
            self.init(pageIndex: pageIndex, regions: regions, plan: plan)
        }

        package init(pageIndex: Int, regions: [DrawnRegion], plan: PaintPlan?) {
            self.pageIndex = pageIndex
            self.regions = regions
            self.plan = plan
        }
    }

    /// A region as drawn: its id and its rectangle as a share of the page
    /// (0 to 1, origin bottom-left), unclamped. An edge may lie off the page.
    public struct DrawnRegion: Equatable, Sendable {
        public let id: UUID
        public let normalizedRect: CGRect

        public init(id: UUID, normalizedRect: CGRect) {
            self.id = id
            self.normalizedRect = normalizedRect
        }
    }

    // MARK: - Part 2: what the producer says it did

    /// The producer's own account of the run. Each field is written by the
    /// step it describes and read only by a check or a test, never by the
    /// producer.
    public struct Produced: Equatable, Sendable {
        /// The SHA-256 of each page's image as it was handed to the writer,
        /// by page index.
        package var pageImageDigests: [Int: Data]
        /// The rectangle the rasterizer reports having painted for each box.
        package var paintedRectangles: [BoxPosition: PaintedPixels]
        /// The regions the rasterizer painted that no box of the page's plan
        /// holds, by page index: painted on their own, and read by the
        /// position check as not checked.
        package var regionsPaintedOutsideThePlan: [Int: Set<UUID>] = [:]
        /// Which way found the information dictionary for its rewrite; nil
        /// until the rewrite has run.
        package var infoDictionary: InfoDictionaryWay?

        /// Nothing produced yet.
        public init() {
            self.init(pageImageDigests: [:], paintedRectangles: [:], infoDictionary: nil)
        }

        package init(
            pageImageDigests: [Int: Data],
            paintedRectangles: [BoxPosition: PaintedPixels],
            infoDictionary: InfoDictionaryWay?
        ) {
            self.pageImageDigests = pageImageDigests
            self.paintedRectangles = paintedRectangles
            self.infoDictionary = infoDictionary
        }
    }
}

extension RunRecord.Produced {
    /// Records what the rasterizer reports for one page: the rectangle it
    /// painted for each box of the page's plan, and the regions it painted
    /// outside the plan. The one writer of both fields.
    public mutating func record(_ result: RasterizeResult, pageIndex: Int) {
        for (box, pixels) in result.paintedBoxes {
            paintedRectangles[RunRecord.BoxPosition(pageIndex: pageIndex, box: box)] = pixels
        }
        if !result.regionsPaintedOutsideThePlan.isEmpty {
            regionsPaintedOutsideThePlan[pageIndex] = result.regionsPaintedOutsideThePlan
        }
    }

    /// Records what the writer reports for the file: which way found the
    /// information dictionary for its rewrite. The one writer of that field
    /// in a run; what the rasterizer recorded is kept.
    public mutating func record(writer account: RunRecord.Produced) {
        infoDictionary = account.infoDictionary
    }
}

extension RunRecord {
    /// A box of a page's plan: the page, and the box's place in that page's
    /// plan, from 0.
    package struct BoxPosition: Hashable, Sendable {
        package let pageIndex: Int
        package let box: Int

        package init(pageIndex: Int, box: Int) {
            self.pageIndex = pageIndex
            self.box = box
        }
    }

    /// A rectangle of whole pixels in a page's image, with its rows counted
    /// from the image's bottom edge, as the engine's fill rectangles are. The
    /// image is coded from its top row: a reader of the image converts.
    package struct PaintedPixels: Hashable, Sendable {
        /// The first column, from the image's left edge.
        package let firstColumn: Int
        /// The first row, counted from the image's bottom edge.
        package let firstRowFromBottom: Int
        /// How many columns the rectangle spans.
        package let columns: Int
        /// How many rows the rectangle spans.
        package let rows: Int

        package init(firstColumn: Int, firstRowFromBottom: Int, columns: Int, rows: Int) {
            self.firstColumn = firstColumn
            self.firstRowFromBottom = firstRowFromBottom
            self.columns = columns
            self.rows = rows
        }
    }

    /// Which way found the information dictionary: by the file's index, or
    /// by the search of the file's tail where the index refused, or neither.
    package enum InfoDictionaryWay: Hashable, Sendable {
        /// The index named the dictionary and at least one literal in it
        /// was rewritten.
        case byIndex
        /// The index named the dictionary and every literal in it declined
        /// (the guards of `overwriteInfoLiterals`); nothing was rewritten.
        case byIndexNothingRewritten
        case byTail(indexRefused: IndexRefusal)
        case neither(indexRefused: IndexRefusal)
    }

    /// Why the first way would not name the dictionary. The first way reads
    /// only a classic cross-reference table and an uncompressed object.
    package enum IndexRefusal: Hashable, Sendable, CaseIterable {
        /// The file's index is a cross-reference stream.
        case crossReferenceStream
        /// The trailer has a `/Prev` entry.
        case previousSection
        /// The trailer has no `/Info` entry.
        case noInfoEntry
        /// The table's entry for the dictionary is not in use.
        case entryNotInUse
        /// The object at the entry's offset is not the one the trailer named.
        case wrongObjectHeader
        /// The dictionary does not close within 4,096 bytes.
        case dictionaryNotClosed
        /// A key occurs twice in the dictionary.
        case repeatedKey
        /// The index could not be read: no `startxref` near the end, an
        /// offset that is not a number or lies past the end, a table whose
        /// entries do not parse, or a trailer that does not close.
        case indexUnreadable
        /// The file could not be read or written through the index (an I/O
        /// error on the mapped read, the handle, the seek or the write).
        case readOrWriteFailed
    }
}
