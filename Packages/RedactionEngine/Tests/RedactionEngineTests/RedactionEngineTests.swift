import Testing
import Foundation
import CoreGraphics
@testable import RedactionEngine

@Suite("RedactionEngine Model Types")
struct ModelTypeTests {

    // MARK: - PipelineMode & TextLayerStatus

    @Test("PipelineMode raw values round-trip")
    func pipelineModeRawValues() {
        #expect(PipelineMode(rawValue: "secureRasterization") == .secureRasterization)
        #expect(PipelineMode(rawValue: "searchableRedaction") == .searchableRedaction)
        #expect(PipelineMode.allCases.count == 2)
    }

    @Test("TextLayerStatus cases exist")
    func textLayerStatus() {
        let statuses: [TextLayerStatus] = [.rich, .sparse, .none]
        #expect(statuses.count == 3)
    }

    // MARK: - FillColor

    @Test("FillColor raw values round-trip")
    func fillColorRawValues() {
        #expect(FillColor(rawValue: "black") == .black)
        #expect(FillColor(rawValue: "white") == .white)
        #expect(FillColor.allCases.count == 2)
    }

    @Test("FillColor cgColor produces non-nil values")
    func fillColorCGColor() {
        #expect(FillColor.black.cgColor.numberOfComponents > 0)
        #expect(FillColor.white.cgColor.numberOfComponents > 0)
    }

    @Test("ExpectedPixelBGRA values match fill colors")
    func expectedPixelValues() {
        let black = FillColor.black.expectedPixel
        #expect(black == ExpectedPixelBGRA(b: 0, g: 0, r: 0, a: 255))

        let white = FillColor.white.expectedPixel
        #expect(white == ExpectedPixelBGRA(b: 255, g: 255, r: 255, a: 255))
    }

    // MARK: - RedactionRegion

    @Test("RedactionRegion is Identifiable and Equatable")
    func redactionRegionEquality() {
        let id = UUID()
        let r1 = RedactionRegion(id: id, normalizedRect: .zero, source: .manual)
        let r2 = RedactionRegion(id: id, normalizedRect: .zero, source: .manual)
        #expect(r1 == r2)
    }

    @Test("RedactionRegion source types are distinct")
    func redactionRegionSources() {
        let manual = RedactionRegion.Source.manual
        let pii = RedactionRegion.Source.detectedPII(kind: .ssn)
        let face = RedactionRegion.Source.detectedFace
        #expect(manual != pii)
        #expect(manual != face)
        #expect(pii != face)
    }

    // MARK: - VerificationStatus custom Equatable

    @Test("VerificationStatus compares case identity only, ignoring associated strings")
    func verificationStatusEquality() {
        // Same case, different messages — should be equal (ARCH §2.3)
        #expect(VerificationStatus.warn("message A") == VerificationStatus.warn("message B"))
        #expect(VerificationStatus.fail("reason 1") == VerificationStatus.fail("reason 2"))

        // Different cases — should not be equal
        #expect(VerificationStatus.pass != VerificationStatus.fail("x"))
        #expect(VerificationStatus.warn("x") != VerificationStatus.fail("x"))
        #expect(VerificationStatus.pass != VerificationStatus.skipped)
    }

    // MARK: - VerificationReport

    @Test("VerificationReport.skipped sentinel is correct")
    func verificationReportSkipped() {
        let skipped = VerificationReport.skipped
        #expect(skipped.overallStatus == .skipped)
        #expect(skipped.layers.isEmpty)
        #expect(skipped.durationSeconds == 0)
    }

    // MARK: - DetectionResult

    @Test("DetectionResult.toRegion converts correctly")
    func detectionResultToRegion() {
        let det = DetectionResult(
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            kind: .pii(.ssn),
            confidence: 0.95
        )
        let region = det.toRegion()
        #expect(region.normalizedRect == det.normalizedRect)
        #expect(region.source == .detectedPII(kind: .ssn))
        #expect(region.id != det.id) // Fresh UUID
    }

    @Test("DetectionResult face kind converts to detectedFace source")
    func detectionResultFaceToRegion() {
        let det = DetectionResult(
            normalizedRect: .zero,
            kind: .face,
            confidence: 0.8
        )
        let region = det.toRegion()
        #expect(region.source == .detectedFace)
    }

    // MARK: - PipelineError

    @Test("PipelineError provides user-facing error descriptions")
    func pipelineErrorDescriptions() {
        let err = PipelineError.importError(.corrupt)
        #expect(err.errorDescription != nil)
        #expect(err.errorDescription!.contains("could not be opened"))
    }

    @Test("PipelineError.pageIndex extracts page for relevant cases")
    func pipelineErrorPageIndex() {
        #expect(PipelineError.redactionError(.bitmapCreationFailed(pageIndex: 3)).pageIndex == 3)
        #expect(PipelineError.redactionError(.reconstructionFailed).pageIndex == nil)
        #expect(PipelineError.importError(.corrupt).pageIndex == nil)
    }

    @Test("PipelineError.isRecoverable flags correctly")
    func pipelineErrorRecoverable() {
        #expect(PipelineError.importError(.corrupt).isRecoverable == false)
        #expect(PipelineError.redactionError(.reconstructionFailed).isRecoverable == true)
        #expect(PipelineError.exportError(.diskFull).isRecoverable == false)
        #expect(PipelineError.exportError(.filePurged).isRecoverable == true)
    }

    // MARK: - CharacterInfo

    @Test("CharacterInfo stores character identity and position")
    func characterInfo() {
        let ci = CharacterInfo(
            character: "A",
            bounds: CGRect(x: 10, y: 20, width: 8, height: 12),
            stringIndex: 0
        )
        #expect(ci.character == "A")
        #expect(ci.bounds.width == 8)
        #expect(ci.stringIndex == 0)
    }

    // MARK: - PageOutput & RasterizeResult

    @Test("PageOutput accepts nil textLayerEntries for Secure Rasterization")
    func pageOutputSecureMode() {
        // Create a minimal 1x1 CGImage for testing
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
                       | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: nil, width: 1, height: 1,
                                  bitsPerComponent: 8, bytesPerRow: 16,
                                  space: colorSpace, bitmapInfo: bitmapInfo),
              let image = ctx.makeImage() else {
            Issue.record("Could not create test CGImage")
            return
        }
        let output = PageOutput(image: image, size: CGSize(width: 1, height: 1),
                                textLayerEntries: nil)
        #expect(output.textLayerEntries == nil)
    }

    @Test("RasterizeResult pairs output with optional digest")
    func rasterizeResult() {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
                       | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: nil, width: 1, height: 1,
                                  bitsPerComponent: 8, bytesPerRow: 16,
                                  space: colorSpace, bitmapInfo: bitmapInfo),
              let image = ctx.makeImage() else {
            Issue.record("Could not create test CGImage")
            return
        }
        let output = PageOutput(image: image, size: CGSize(width: 1, height: 1),
                                textLayerEntries: nil)
        let result = RasterizeResult(pageOutput: output, filterDigest: nil)
        #expect(result.filterDigest == nil)
    }
}
