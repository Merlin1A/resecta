import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The results screen's line for where a check stopped at an issue before it
// had read everything. The seventeen rows are the engine's own, as its table
// (`CheckStopTests`) pins them: status, pages and where the check stopped;
// each row here reads its opened block's lead lines. The line follows
// whatever lead the row has, and a check that read everything shows none.

@Suite("The results row says where a check stopped")
struct CheckStopLineTests {

    static let tbl = "Image EXIF was not searched after this match."
    static let tal = "Bookmarks and form fields were not read after this find."  // LegalPhrases:safe (approved row words)
    static let talB = "Form fields were not read after this find."  // LegalPhrases:safe (approved row words)
    static let acl = "Checking stopped at this find. Not everything this check looks for was checked."  // LegalPhrases:safe (approved row words)
    static func tbx(page: Int) -> String { "The EXIF search stopped at page \(page). EXIF in images on later pages was not searched." }
    static let review = VerificationRowModel.reviewLead(termCount: 1)

    struct Row: Sendable, CustomTestStringConvertible {
        let id: String
        let layer: VerificationLayer
        let status: VerificationStatus
        let pages: [Int]?
        let pageCount: Int
        let stopped: CheckStop?
        let outcome: VerificationOutcome
        let lead: [String]
        var testDescription: String { id }
    }

    static let term = "Quillfeather"

    static let rows: [Row] = [
        Row(id: "S-1", layer: .binaryStringSearch, status: .fail("Sensitive string found in output PDF structural data (1 match(es))"),
            pages: nil, pageCount: 1, stopped: .imageEXIFNotSearched, outcome: .failed, lead: [tbl]),
        Row(id: "S-2", layer: .binaryStringSearch, status: .attention("Text matching your redactions is still readable on page 1 (1 instance)"),
            pages: [0], pageCount: 1, stopped: .imageEXIFNotSearched, outcome: .needsReview, lead: [review, tbl]),
        Row(id: "S-3", layer: .binaryStringSearch, status: .warn("Possible sensitive term fragment in output PDF structural data (1 match(es))"),
            pages: nil, pageCount: 1, stopped: .imageEXIFNotSearched, outcome: .warning, lead: [tbl]),
        Row(id: "S-4", layer: .binaryStringSearch, status: .warn("Sensitive term found in embedded JPEG EXIF metadata on page 3"),
            pages: [2], pageCount: 5, stopped: .exifSearchStopped(page: 2), outcome: .warning, lead: [tbx(page: 3)]),
        Row(id: "S-5", layer: .binaryStringSearch, status: .warn("Sensitive term found in embedded JPEG EXIF metadata on page 5"),
            pages: [4], pageCount: 5, stopped: .exifSearchStopped(page: 4), outcome: .warning, lead: []),
        Row(id: "S-6", layer: .textExtraction, status: .fail("Selectable text found on page 1"),
            pages: [0], pageCount: 1, stopped: .bookmarksAndFormFieldsNotRead, outcome: .failed, lead: [tal]),
        Row(id: "S-7", layer: .textExtraction, status: .fail("Bookmarks found in output"),
            pages: nil, pageCount: 1, stopped: .formFieldsNotRead, outcome: .failed, lead: [talB]),
        Row(id: "S-8", layer: .textExtraction, status: .fail("Form fields found in output"),
            pages: nil, pageCount: 1, stopped: nil, outcome: .failed, lead: []),
        Row(id: "S-9", layer: .structureCheck, status: .fail("Encrypt found in document"),
            pages: nil, pageCount: 1, stopped: .stoppedAtThisFind, outcome: .failed, lead: [acl]),
        Row(id: "S-10", layer: .structureCheck, status: .fail("OpenAction found in document catalog"),
            pages: nil, pageCount: 1, stopped: .stoppedAtThisFind, outcome: .failed, lead: [acl]),
        Row(id: "S-11", layer: .structureCheck, status: .fail("Per-page /AA (automatic action) found on 1 page"),
            pages: [1], pageCount: 2, stopped: .stoppedAtThisFind, outcome: .failed, lead: [acl]),
        Row(id: "S-12", layer: .structureCheck, status: .fail("Multiple %%EOF markers (2) — incremental update may contain original content"),
            pages: nil, pageCount: 1, stopped: nil, outcome: .failed, lead: []),
        Row(id: "S-13", layer: .metadataCheck, status: .fail("Metadata key /Title present"),
            pages: nil, pageCount: 1, stopped: .stoppedAtThisFind, outcome: .failed, lead: [acl]),
        Row(id: "S-14", layer: .metadataCheck, status: .fail("Non-standard /Info key(s): Department"),
            pages: nil, pageCount: 1, stopped: .stoppedAtThisFind, outcome: .failed, lead: [acl]),
        Row(id: "S-15", layer: .metadataCheck, status: .warn("Producer or timestamp fields were not rewritten to the fixed values"),
            pages: nil, pageCount: 1, stopped: .stoppedAtThisFind, outcome: .warning, lead: [acl]),
        Row(id: "S-16", layer: .metadataCheck, status: .warn("File identifier was not derived from the file contents"),
            pages: nil, pageCount: 1, stopped: nil, outcome: .warning, lead: []),
        Row(id: "S-17", layer: .operatorReExtraction, status: .attention("A redacted term was found in a content stream on page 3"),
            pages: [2], pageCount: 5, stopped: nil, outcome: .needsReview,
            lead: [review, "Scanning stopped at page 3. Later pages were not searched."]),
    ]

    static func layer(_ r: Row) -> LayerResult {
        let sentence: String = switch r.status {
        case .warn(let m), .info(let m), .attention(let m), .fail(let m), .notApplicable(let m): m
        case .pass, .skipped: ""
        }
        return LayerResult(name: r.layer.rawValue, symbolName: "doc", status: r.status, shortDescription: sentence,
                           detailDescription: sentence, pageReferences: r.pages, durationSeconds: 0,
                           reviewTermTexts: r.status.isAttention ? [term] : nil, layer: r.layer, stopped: r.stopped)
    }

    @Test("The table holds seventeen rows")
    func tableLength() {
        #expect(Self.rows.count == 17)
        #expect(Set(Self.rows.map(\.id)).count == 17)
    }

    @Test("Each row's opened block: its lead, then where the check stopped", arguments: Self.rows)
    func lead(_ r: Row) {
        let layer = Self.layer(r)
        let modes = Array(repeating: PipelineMode.secureRasterization, count: r.pageCount)
        let outcome = VerificationRowModel.outcome(for: layer, perPageModes: modes)
        #expect(outcome == r.outcome, "\(r.id): \(outcome)")
        #expect(VerificationRowModel.lead(for: layer, outcome: outcome, perPageModes: modes) == r.lead, "\(r.id)")
    }

    @Test("No line where the check read everything, or for the EXIF stop when the page count is unknown")
    func noLine() {
        #expect(VerificationRowModel.stopLine(nil, pageCount: 3) == nil)
        #expect(VerificationRowModel.stopLine(.exifSearchStopped(page: 0), pageCount: 0) == nil)
    }
}
