import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// The import guard refuses a document that carries JavaScript at any of the
// ISO-canonical locations, and reports it as active content — its own case
// with its own copy — rather than as a damaged file.

@Suite("Import active-content refusal", .tags(.importFlow))
@MainActor
struct ImportActiveContentTests {

    // MARK: - Refusal at each location

    @Test("JavaScript at each canonical location is refused as active content, not as damaged")
    func javaScriptLocationsAreRefusedAsActiveContent() async {
        let probes: [(String, Data, (ActiveContentLocation) -> Bool)] = [
            ("catalog /JavaScript", Self.catalogJavaScriptPDF(),
             { $0 == .catalogKey("JavaScript") }),
            ("/Names → /JavaScript", Self.namesJavaScriptPDF(),
             { $0 == .namesJavaScript }),
            ("/OpenAction JavaScript", Self.openActionJavaScriptPDF(),
             { $0 == .openAction }),
            ("page /AA JavaScript", Self.pageAdditionalActionJavaScriptPDF(),
             { $0 == .pageAdditionalAction(pageIndex: 0) }),
            ("annotation /A JavaScript", Self.annotationActionJavaScriptPDF(),
             { $0 == .annotationAction(pageIndex: 0) }),
        ]
        for (label, data, matches) in probes {
            let doc = DocumentState()
            let redaction = RedactionState()
            await ImportService.importDocument(
                data: data, suggestedType: "pdf",
                documentState: doc, redactionState: redaction)

            guard case .failed(let error, let returnPhase) = doc.phase else {
                Issue.record("\(label): expected .failed, got \(doc.phaseKind)")
                continue
            }
            guard case .importError(.activeContent(let location)) = error else {
                Issue.record("\(label): expected .importError(.activeContent), got \(error)")
                continue
            }
            #expect(matches(location), "\(label): unexpected location \(location)")
            if case .empty = returnPhase {} else {
                Issue.record("\(label): a first import returns to empty, got \(returnPhase)")
            }
            #expect(doc.sourceDocument == nil, "\(label): nothing may be loaded")
        }
    }

    @Test("A clean document with an /OpenAction destination still imports")
    func openActionDestinationImports() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        await ImportService.importDocument(
            data: Self.openActionDestinationPDF(), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)
        #expect(doc.phaseKind == .editing)
        #expect(doc.sourceDocument != nil)
    }

    @Test("An active-content refusal from the editor returns to the editor")
    func refusalFromEditingReturnsToEditing() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        await ImportService.importDocument(
            data: makeTestPDFData(), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)
        #expect(doc.phaseKind == .editing)

        await ImportService.importDocument(
            data: Self.openActionJavaScriptPDF(), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)
        guard case .failed(let error, let returnPhase) = doc.phase else {
            Issue.record("expected .failed, got \(doc.phaseKind)")
            return
        }
        guard case .importError(.activeContent) = error else {
            Issue.record("expected .importError(.activeContent), got \(error)")
            return
        }
        if case .editing = returnPhase {} else {
            Issue.record("a refusal from the editor returns to editing, got \(returnPhase)")
        }
    }

    // MARK: - Copy

    @Test("Active-content copy names the mechanism, not a damaged file")
    func activeContentCopy() {
        let error = PipelineError.importError(.activeContent(location: .openAction))
        #expect(error.localizedTitle == "Document Contains Active Content")
        #expect(error.localizedRecovery.hasPrefix("This document contains JavaScript or a launch action."))
        #expect(error.localizedDescription.contains("JavaScript or a launch action"))
        #expect(error.isRecoverable == false)
        let damaged = PipelineError.importError(.corrupt)
        #expect(error.localizedTitle != damaged.localizedTitle)
        #expect(error.localizedRecovery != damaged.localizedRecovery)
        // Forbidden absolutes assembled from halves so this source does not
        // itself trip the M-1 sweep (mirrors HonestySurfacesTests).
        let halves: [(String, String)] = [
            ("guaran", "tee"), ("ens", "ure"), ("imposs", "ible"),
            ("perfect", "ly"), ("flaw", "lessly"), ("10", "0%"),
        ]
        for text in [error.localizedTitle, error.localizedRecovery, error.localizedDescription] {
            let lower = text.lowercased()
            #expect(!lower.contains("damaged"), "active-content copy must not read as damage: \(text)")
            for banned in LegalPhrases.bannedTerms {
                #expect(!lower.contains(banned.lowercased()), "banned term '\(banned)' in: \(text)")
            }
            for (a, b) in halves {
                #expect(!lower.contains(a + b), "forbidden phrase '\(a + b)' in: \(text)")
            }
        }
    }

    // MARK: - Raw fixtures (the engine's factories are not visible to this target)

    /// Objects numbered from 1 in order, a valid cross-reference table.
    private static func rawPDF(_ objects: [String]) -> Data {
        var body = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, content) in objects.enumerated() {
            offsets.append(body.utf8.count)
            body += "\(index + 1) 0 obj\n\(content)\nendobj\n"
        }
        let xrefOffset = body.utf8.count
        body += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            body += String(format: "%010d 00000 n \n", offset)
        }
        body += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        return Data(body.utf8)
    }

    private static let javaScriptAction =
        "<< /Type /Action /S /JavaScript /JS (app.alert\\('probe'\\)) >>"

    /// One blank page; extras spliced into the catalog and the page, extra
    /// objects numbered from 5.
    private static func probe(catalogExtras: String = "", pageExtras: String = "",
                              extraObjects: [String] = []) -> Data {
        rawPDF([
            "<< /Type /Catalog /Pages 2 0 R \(catalogExtras) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> \(pageExtras) >>",
            "<< /Length 0 >>\nstream\n\nendstream",
        ] + extraObjects)
    }

    static func catalogJavaScriptPDF() -> Data {
        probe(catalogExtras: "/JavaScript << /Names [(script1) 5 0 R] >>",
              extraObjects: [javaScriptAction])
    }

    static func namesJavaScriptPDF() -> Data {
        probe(catalogExtras: "/Names << /JavaScript << /Names [(onOpen) 5 0 R] >> >>",
              extraObjects: [javaScriptAction])
    }

    static func openActionJavaScriptPDF() -> Data {
        probe(catalogExtras: "/OpenAction 5 0 R", extraObjects: [javaScriptAction])
    }

    static func openActionDestinationPDF() -> Data {
        probe(catalogExtras: "/OpenAction [3 0 R /Fit]")
    }

    static func pageAdditionalActionJavaScriptPDF() -> Data {
        probe(pageExtras: "/AA << /O 5 0 R >>", extraObjects: [javaScriptAction])
    }

    static func annotationActionJavaScriptPDF() -> Data {
        probe(pageExtras: "/Annots [6 0 R]",
              extraObjects: [
                javaScriptAction,
                "<< /Type /Annot /Subtype /Link /Rect [72 700 172 730] /A 5 0 R >>",
              ])
    }
}
