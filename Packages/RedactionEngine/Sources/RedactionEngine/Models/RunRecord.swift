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

        public init(pageIndex: Int, regions: [DrawnRegion]) {
            self.init(pageIndex: pageIndex, regions: regions, plan: nil)
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
        case byIndex
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
    }
}
