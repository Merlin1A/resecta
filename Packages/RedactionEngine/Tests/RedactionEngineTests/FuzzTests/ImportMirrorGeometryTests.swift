import Foundation
import PDFKit
import Testing
@testable import RedactionEngine

// The robustness runner's import mirror refuses, at the app's geometry
// stage, the pages the render would refuse: a non-default `/UserUnit` and a
// side under 10 pt. The app-side parity pin holds the two stage lists equal.

@Suite("Import mirror: page geometry")
struct ImportMirrorGeometryTests {

    private func refusal(_ data: Data) -> String {
        switch RobustnessRunnerTests.importMirror(data) {
        case .reject(let errorClass): return errorClass
        case .open: return "open"
        }
    }

    @Test("A /UserUnit page is refused as unsupported page geometry")
    func userUnitPageIsRefused() {
        #expect(refusal(TestFixtures.userUnitPDF(userUnit: 2.0)) == "unsupportedPageGeometry")
    }

    @Test("A page with a side under 10 pt is refused as unsupported page geometry")
    func tinyPageIsRefused() {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 5, height: 5)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
        #expect(refusal(data as Data) == "unsupportedPageGeometry")
    }

    @Test("A standard text page still opens")
    func textPageOpens() {
        #expect(refusal(TestFixtures.userUnitPDF(userUnit: 1.0)) == "open")
    }
}
