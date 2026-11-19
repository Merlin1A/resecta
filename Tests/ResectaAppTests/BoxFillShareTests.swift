import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The Box Fill row on today's results screen and at Share: a report whose
// only trouble is this row. An issue asks through the reported-issues confirm
// and the masthead asks that it be read; a box it could not
// check, and a run with no record, ask through the incomplete-checks
// confirm.

@Suite("The Box Fill row at the masthead and at Share")
@MainActor
struct BoxFillShareTests {

    private typealias Editor = DocumentEditorView

    /// Every Secure check passing except Box Fill, which reads `boxFill`; the
    /// overall status as the engine aggregates it.
    private func report(_ boxFill: LayerResult) -> VerificationReport {
        let engine = VerificationEngine()
        let layers = engine.layers(for: .secureRasterization).map { layer in
            layer == .boxFill ? boxFill : LayerResult(
                name: layer.name, symbolName: layer.symbolName, status: .pass, shortDescription: "No issues found.",
                detailDescription: "", pageReferences: nil, durationSeconds: 0, layer: layer)
        }
        return VerificationReport(layers: layers, overallStatus: engine.aggregateStatus(layers), durationSeconds: 1,
                                  perPageModes: [.secureRasterization])
    }

    private func row(_ status: VerificationStatus, short: String, detail: String = "", pages: [Int]? = nil,
                     cnv: Bool = false) -> LayerResult {
        LayerResult(name: VerificationLayer.boxFill.name, symbolName: VerificationLayer.boxFill.symbolName, status: status,
                    shortDescription: short, detailDescription: detail, pageReferences: pages, durationSeconds: 0,
                    layer: .boxFill, couldNotVerify: cnv)
    }

    private func kindID(_ report: VerificationReport) -> String? {
        let doc = DocumentState()
        doc.phase = .verified(report: report)
        return Editor.shareConfirmKind(report: report, documentState: doc, concealedPages: [])?.id
    }

    @Test("An issue: Needs Review, the masthead asks that it be read, Share asks with reported issues")
    func issue() {
        let issue = report(row(.attention("A box on page 4 is not exactly the fill."),
                              short: "A box on page 4 is not exactly the fill.",
                              detail: "This check is new and has not yet been shown to stay quiet on correct files.", pages: [3]))
        #expect(issue.overallStatus.isAttention)
        #expect(VerificationMasthead.mastheadSubtitle(report: issue) == "Read the finding below before you share the PDF.") // LegalPhrases:safe (approved words)
        #expect(kindID(issue) == "failOrAttention")
        #expect(VerificationRowModel(layer: issue.layers.last!, perPageModes: [.secureRasterization]).outcome == .needsReview)
    }

    @Test("A box it could not check: Could not verify, Share asks with incomplete checks")
    func couldNotCheck() {
        let unchecked = report(row(.warn("A box on page 4 could not be checked."),
                                   short: "A box on page 4 could not be checked.", pages: [3], cnv: true))
        #expect(unchecked.overallStatus.isWarn)
        #expect(kindID(unchecked) == "incompleteWarn")
        #expect(VerificationRowModel(layer: unchecked.layers.last!, perPageModes: [.secureRasterization]).outcome == .couldNotVerify)
    }

    @Test("No record: Skipped, read as Could not verify with the existing caption, Share asks with incomplete checks")
    func noRecord() {
        let skipped = report(row(.skipped, short: "Skipped."))
        #expect(skipped.overallStatus.isWarn)
        #expect(kindID(skipped) == "incompleteWarn")
        let model = VerificationRowModel(layer: skipped.layers.last!, perPageModes: [.secureRasterization])
        #expect(model.outcome == .couldNotVerify)
        #expect(model.outcome != .nothingToCheck)
    }

    @Test("Two needs-review rows with no term to search: the plural sentence")
    func twoFindings() {
        var two = report(row(.attention("x"), short: "x", pages: [3]))
        var layers = two.layers
        let metadata = layers.firstIndex { $0.layer == .metadataCheck }!
        layers[metadata] = LayerResult(name: "Metadata Check", symbolName: "info.circle", status: .attention("y"),
                                       shortDescription: "y", detailDescription: "", pageReferences: nil,
                                       durationSeconds: 0, layer: .metadataCheck)
        two = VerificationReport(layers: layers, overallStatus: .attention("x"), durationSeconds: 1,
                                 perPageModes: [.secureRasterization])
        #expect(VerificationMasthead.mastheadSubtitle(report: two) == "Read the findings below before you share the PDF.") // LegalPhrases:safe (approved words)
    }
}
