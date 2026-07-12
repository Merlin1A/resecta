import Foundation
import PDFKit
import Testing
@testable import RedactionEngine

// S8 step-4 diagnostic — isolates the Vision Code=9 ("Could not create
// inference context") seen on the FIRST 200-DPI OCR invocation of a fresh
// process during the DPI A/B. Run alone (own struct so -only-testing can
// target it; Swift Testing filters match at struct level):
//
//   xcodebuild test-without-building … \
//     -only-testing:RedactionEngineTests/Vision200ColdStartProbeTests
//
// Print-only measurement (never gates): reports whether the first 200-DPI
// call fails on SYNTHETIC content (content-independence) and whether an
// immediate same-image retry succeeds (decides the production mitigation).

@Suite("Vision 200-DPI cold-start probe", .serialized)
struct Vision200ColdStartProbeTests {

    @Test("First 200-DPI Vision call in a fresh process — fail/retry behavior")
    func coldStartProbe() async throws {
        let pdfData = TwentyPageFixtureBuilder.buildDocument()
        let document = try #require(PDFDocument(data: pdfData))
        let page = try #require(document.page(at: 0))
        let rasterizer = PageRasterizer()
        let orchestrator = DetectionOrchestrator(recognitionLevel: .fast)

        let image = try await rasterizer.renderPage(page, pageIndex: 0, dpi: 200)
        print("[OCRQ-cold] first 200-DPI image px=\(image.width)x\(image.height)")

        func attempt(_ label: String) async -> String {
            do {
                let result = try await orchestrator.detectPage(
                    image: image, pageIndex: 0,
                    priors: PerCategoryPriors(),
                    surfaceForms: SurfaceFormDictionary(),
                    doctypeContext: nil, thresholdVector: nil,
                    embeddedText: nil, ocrSkipReason: nil
                )
                return "\(label)=ok detections=\(result.detections.count)"
            } catch { // LegalPhrases:safe (Swift keyword)
                let ns = error as NSError
                return "\(label)=fail \(ns.domain)#\(ns.code)"
            }
        }

        let first = await attempt("first")
        let second = await attempt("retry")
        print("[OCRQ-cold] \(first) \(second)")
    }
}
