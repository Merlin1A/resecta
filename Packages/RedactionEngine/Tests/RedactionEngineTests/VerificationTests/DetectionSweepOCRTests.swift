import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// The Detection Sweep's tier on image-only output, read by OCR: an item
// left in a category the user's scan applied is something the scan should
// have caught (ATTENTION); an item only in a category no scan covered stays
// a note. Vision-backed, simulator-only like the other OCR suites; every
// value is public fixture vocabulary (the threshold suites' synthetic SSN).

@Suite("Detection Sweep (OCR route)", .serialized)
struct DetectionSweepOCRTests {

    private func scan(_ categories: Set<PIICategory>, origin: SearchRecheckRequest.Origin) -> SearchRecheckRequest {
        SearchRecheckRequest(
            record: AppliedSearchRecord(
                query: AppliedSearchQuery(kind: .piiScan(categories: categories), options: SearchOptions()),
                foundCount: origin == .applied ? 1 : 0),
            appliedCount: origin == .applied ? 1 : 0, appliedPages: origin == .applied ? [0] : [],
            origin: origin)
    }

    private func ssnImagePage() async throws -> (SendablePDFDocument, URL) {
        let img = try TestFixtures.renderedTextImage("SSN 123-45-6789", width: 1200, height: 1500, fontSize: 90)
        let (doc, url) = try await TestFixtures.imagePagesPDF([img], size: CGSize(width: 1200, height: 1500))
        #expect((doc.page(at: 0)?.string ?? "").isEmpty, "the fixture must carry no text layer")
        return (SendablePDFDocument(doc), url)
    }

    @Test("An SSN in an image after an SSN Scan reads ATTENTION, with the page chip")
    func ssnInImageAfterSSNScanIsAttention() async throws {
        let (doc, url) = try await ssnImagePage()
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = try await DetectionSweep().run(
            outputDocument: doc,
            requests: [scan([.ssn], origin: .applied), scan(Set(PIICategory.allCases), origin: .sweep)],
            observations: nil)
        #expect(outcome.status.isAttention, "the applied scan's own category remains; got \(outcome.status)")
        #expect(outcome.pageReferences == [0])
        #expect(outcome.queryLines?.first?.route == .ocr)
        #expect(outcome.reviewTermTexts == nil, "the status names no matched text")
    }

    @Test("An SSN in an image after a Phone-only Scan stays a note: the SSN category was never scanned")
    func ssnInImageOutsideTheAppliedScanStaysANote() async throws {
        let (doc, url) = try await ssnImagePage()
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = try await DetectionSweep().run(
            outputDocument: doc,
            requests: [scan([.phone], origin: .applied), scan(Set(PIICategory.allCases), origin: .sweep)],
            observations: nil)
        #expect(outcome.status.isInfo, "an item outside every applied category is a possible item; got \(outcome.status)")
        #expect(outcome.pageReferences == [0])
    }

    @Test("No scan applied and no sweep requested reads NOT APPLICABLE, never a pass")
    func noScanIsNotApplicable() async throws {
        let (doc, url) = try await ssnImagePage()
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = try await DetectionSweep().run(outputDocument: doc, requests: [], observations: nil)
        #expect(outcome.status == .notApplicable(DetectionSweep.infoMessage))
        #expect(outcome.queryLines == nil)
    }
}
