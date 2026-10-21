import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// The source copy the verification's coverage check reads. A document
// unlocked with a password re-emits its bytes still encrypted for the 40-
// and 128-bit revisions, so a bare copy opens locked and reads no text: the
// runner unlocks its copy with the session's password, as the search path
// does, and a copy that stays locked is nil — the layer then reports that
// the check did not run, never a pass over a document it could not read.

@Suite("Verification source copy (the coverage check's original pages)", .tags(.importFlow))
struct VerificationSourceCopyTests {

    nonisolated static let fixtures = ["r3-rc4-128.pdf", "r4-aes-128.pdf"]

    private func unlocked(_ name: String) throws -> SendablePDFDocument {
        let doc = try #require(PDFDocument(data: try ImportLockedDocumentTests.bytes(name)))
        #expect(doc.unlock(withPassword: "user"))
        return SendablePDFDocument(doc)
    }

    private func request(_ term: String) -> SearchRecheckRequest {
        SearchRecheckRequest(
            record: AppliedSearchRecord(query: AppliedSearchQuery(kind: .text(term), options: SearchOptions()), foundCount: 1),
            appliedCount: 1, appliedPages: [0])
    }

    private func recheck(source: SendablePDFDocument?, region: RedactionRegion, request: SearchRecheckRequest) async throws -> LayerResult {
        let output = SendablePDFDocument(try #require(PDFDocument(data: makeTextPDFData(text: "ENCRYPTED 7731"))))
        return await VerificationEngine().runLayer(
            .searchRecheck, outputDocument: output, sourcePageCount: 1,
            regions: [0: [region]], sensitiveTerms: [], pipelineMode: .searchableRedaction,
            filterDigests: [nil], perPageModes: [.searchableRedaction],
            appliedSearches: [request], sourceDocument: source)
    }

    @Test("With the session's password the copy opens; without it, or with no document, there is no copy",
          arguments: fixtures)
    func copyFollowsTheHolder(name: String) throws {
        let source = try unlocked(name)
        let holder = DocumentPasswordHolder()
        #expect(PipelineRunner.verificationSourceCopy(of: source, unlockingWith: holder) == nil,
                "a copy that stays locked is no copy")
        holder.set("user")
        let copy = try #require(PipelineRunner.verificationSourceCopy(of: source, unlockingWith: holder))
        #expect(!copy.document.isLocked)
        #expect(copy.document !== source.document, "the check reads its own instance")
        #expect(copy.document.page(at: 0)?.string?.contains("ENCRYPTED SEED 7731") == true)
        #expect(PipelineRunner.verificationSourceCopy(of: nil, unlockingWith: holder) == nil)
    }

    @Test("On a 128-bit password document the coverage check runs on the unlocked copy: a drifted box fails, the placed box passes; without the password the layer says it could not verify",
          arguments: fixtures)
    func coverageOnTheUnlockedCopy(name: String) async throws {
        let source = try unlocked(name)
        let holder = DocumentPasswordHolder()
        holder.set("user")
        let copy = try #require(PipelineRunner.verificationSourceCopy(of: source, unlockingWith: holder))
        let page = try #require(copy.document.page(at: 0))
        let raw = try #require(page.string)
        let range = (raw as NSString).range(of: "SEED")
        try #require(range.location != NSNotFound)
        let trueRect = try #require(DocumentSearcher().boundingRect(for: range, page: page))
        let request = request("SEED")

        let placed = RedactionRegion(id: UUID(), normalizedRect: trueRect, source: .searchMatch(term: "SEED"))
        let passed = try await recheck(source: copy, region: placed, request: request)
        #expect(passed.status == .pass, "\(name): got \(passed.status)")

        let drifted = RedactionRegion(id: UUID(), normalizedRect: trueRect.offsetBy(dx: trueRect.width * 0.6, dy: 0), source: .searchMatch(term: "SEED"))
        let failed = try await recheck(source: copy, region: drifted, request: request)
        #expect(failed.status.isFail, "\(name): a box drifted off its match must fail — got \(failed.status)")

        // The same drifted box with no copy (the holder empty): never a pass.
        let none = PipelineRunner.verificationSourceCopy(of: source, unlockingWith: DocumentPasswordHolder())
        let blind = try await recheck(source: none, region: drifted, request: request)
        #expect(blind.status.isWarn && blind.couldNotVerify, "\(name): got \(blind.status)")
        let model = VerificationRowModel(layer: blind, perPageModes: [.searchableRedaction])
        #expect(model.outcome == .couldNotVerify)
    }
}
