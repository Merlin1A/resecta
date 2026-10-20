import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// A page the app cannot render — a side under 10 pt, a non-default
// `/UserUnit` — is refused at import, through the loader's one geometry
// stage on the unlocked document, with the error the render would raise;
// the failed screen keeps its matrix for that error (a go-back over an open
// document, another file from the empty state).

@Suite("Import page geometry", .tags(.importFlow))
struct ImportPageGeometryTests {

    private func refusalName(_ data: Data) async -> String {
        do {
            _ = try await PDFImportLoader().load(
                .bytes(data, declaredType: "pdf", door: .files), password: nil, limits: .standard)
            return "none"
        } catch let error as PipelineError {
            if case .redactionError(let e) = error { return "redactionError.\(e)" }
            if case .importError(let e) = error { return "importError.\(e)" }
            return "other"
        } catch {
            return "other"
        }
    }

    /// A page with 5-pt sides through a PDF context.
    private static func fivePointPage() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 5, height: 5)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.fill(CGRect(x: 1, y: 1, width: 2, height: 2))
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// A letter page whose dictionary carries `/UserUnit 2`, with the xref
    /// offsets computed in bytes.
    private static func userUnitPage() -> Data {
        var body = "%PDF-1.4\n"
        var offsets: [Int: Int] = [:]
        let objects: [(Int, String)] = [
            (1, "<< /Type /Catalog /Pages 2 0 R >>"),
            (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            (3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /UserUnit 2 /Contents 4 0 R /Resources << >> >>"),
            (4, "<< /Length 0 >>\nstream\n\nendstream"),
        ]
        for (id, content) in objects {
            offsets[id] = body.utf8.count
            body += "\(id) 0 obj\n\(content)\nendobj\n\n"
        }
        let xrefOffset = body.utf8.count
        var xref = "xref\n0 5\n0000000000 65535 f \n"
        for id in 1...4 {
            xref += String(format: "%010d 00000 n \n", offsets[id] ?? 0)
        }
        body += xref + "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        return Data(body.utf8)
    }

    @Test("A page with a side under 10 pt is refused at import as unsupported page geometry")
    func tinyPageIsRefused() async {
        #expect(PDFDocument(data: Self.fivePointPage())?.pageCount == 1, "the fixture parses")
        #expect(await refusalName(Self.fivePointPage())
                == "redactionError.unsupportedPageGeometry(pageIndex: 0)")
    }

    @Test("A page with a non-default /UserUnit is refused at import as unsupported page geometry")
    func userUnitPageIsRefused() async {
        #expect(PDFDocument(data: Self.userUnitPage())?.pageCount == 1, "the fixture parses")
        #expect(await refusalName(Self.userUnitPage())
                == "redactionError.unsupportedPageGeometry(pageIndex: 0)")
    }

    @Test("A letter page still imports")
    func letterPageImports() async {
        #expect(await refusalName(makeTestPDFData()) == "none")
    }

    @Test("The failed screen's matrix for the geometry refusal: another file from the empty state, back to the editor over an open document")
    func failedScreenMatrix() {
        let error = PipelineError.redactionError(.unsupportedPageGeometry(pageIndex: 0))
        #expect(FailedStateView.primaryAction(error: error, returnPhase: .empty) == .chooseAnotherFile)
        #expect(FailedStateView.primaryAction(error: error, returnPhase: .editing) == .returnToEditor)
    }
}
