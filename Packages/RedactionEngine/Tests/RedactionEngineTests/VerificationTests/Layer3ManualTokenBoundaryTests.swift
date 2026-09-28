import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// A word captured under a manual region joins the term set as a single
// boundary-required token (the app's capture rule; the corpus mirror's
// too). Layer 3's decoded-text pass honours that discipline exactly as it
// does for a lone detected name: the token embedded in a longer word on
// the output's text layer is not a hit; the standalone word is.

@Suite("Layer 3 — a manual-captured single token is boundary-required")
struct Layer3ManualTokenBoundaryTests {

    private func layer3(_ data: Data, term: SensitiveTerm) async throws -> LayerResult {
        let (doc, url) = try TestFixtures.writeTempPDF(data, prefix: "l3_manual_token_")
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = VerificationEngine()
        return await engine.runLayer(
            .binaryStringSearch, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [term],
            pipelineMode: .searchableRedaction, filterDigests: [nil],
            perPageModes: [.searchableRedaction])
    }

    @Test("Embedded in a longer word: the boundary-required token does not flag; the substring form does")
    func embeddedTokenDoesNotFlag() async throws {
        let data = TestFixtures.withSensitiveTermInTextStream(term: "Smithsonian")
        let bounded = try await layer3(data, term: SensitiveTerm(text: "Smith", requiresTokenBoundary: true))
        #expect(bounded.status == .pass, "got \(bounded.status)")
        let substring = try await layer3(data, term: SensitiveTerm(text: "Smith"))
        #expect(substring.status.isAttention, "got \(substring.status)")
    }

    @Test("Standalone: the boundary-required token flags with its text threaded for review")
    func standaloneTokenFlags() async throws {
        let data = TestFixtures.withSensitiveTermInTextStream(term: "Smith")
        let r = try await layer3(data, term: SensitiveTerm(text: "Smith", requiresTokenBoundary: true))
        #expect(r.status.isAttention, "got \(r.status)")
        #expect(r.reviewTermTexts == ["Smith"])
    }
}
