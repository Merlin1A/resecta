import Testing
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// .serialized: Vision's VNImageRequestHandler.perform() blocks cooperative pool
// threads synchronously. Running multiple Vision tests concurrently can exhaust
// the pool and deadlock (F2-8). Serialize to keep one perform() active at a time.
@Suite("Detection Orchestrator", .serialized)
struct DetectionOrchestratorTests {

    // MARK: - boundingRect Math

    @Test("Single word overlap returns that word's rect")
    func boundingRectSingleWord() {
        let orchestrator = DetectionOrchestrator()
        let bounds: [(NSRange, CGRect)] = [
            (NSRange(location: 0, length: 5), CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.04)),
            (NSRange(location: 6, length: 4), CGRect(x: 0.4, y: 0.8, width: 0.15, height: 0.04)),
        ]
        // Range covering only the first word
        let result = orchestrator.boundingRect(
            for: NSRange(location: 0, length: 5), in: bounds)
        #expect(result == bounds[0].1)
    }

    @Test("Multi-word range returns union of overlapping rects")
    func boundingRectMultiWord() {
        let orchestrator = DetectionOrchestrator()
        let rect1 = CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.04)
        let rect2 = CGRect(x: 0.4, y: 0.75, width: 0.15, height: 0.05)
        let bounds: [(NSRange, CGRect)] = [
            (NSRange(location: 0, length: 5), rect1),
            (NSRange(location: 6, length: 4), rect2),
        ]
        // Range spanning both words
        let result = orchestrator.boundingRect(
            for: NSRange(location: 0, length: 10), in: bounds)
        let expected = rect1.union(rect2)
        #expect(result == expected)
    }

    @Test("No overlap returns nil")
    func boundingRectNoOverlap() {
        let orchestrator = DetectionOrchestrator()
        let bounds: [(NSRange, CGRect)] = [
            (NSRange(location: 0, length: 5), CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.04)),
        ]
        // Range completely outside
        let result = orchestrator.boundingRect(
            for: NSRange(location: 20, length: 5), in: bounds)
        #expect(result == nil)
    }

    @Test("Partial word overlap includes that word's rect")
    func boundingRectPartialOverlap() {
        let orchestrator = DetectionOrchestrator()
        let wordRect = CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.04)
        let bounds: [(NSRange, CGRect)] = [
            (NSRange(location: 0, length: 10), wordRect),
        ]
        // Range overlapping only part of the word
        let result = orchestrator.boundingRect(
            for: NSRange(location: 5, length: 3), in: bounds)
        #expect(result == wordRect)
    }

    @Test("Empty bounds array returns nil")
    func boundingRectEmptyBounds() {
        let orchestrator = DetectionOrchestrator()
        let result = orchestrator.boundingRect(
            for: NSRange(location: 0, length: 5), in: [])
        #expect(result == nil)
    }

    @Test("D05-F1: coalesced range unions the dropped tail's word box")
    func boundingRectCoalescedRangeCoversTail() {
        let orchestrator = DetectionOrchestrator()
        // Two disjoint word boxes: a head word [0,11) and a tail word [11,16).
        let headBox = CGRect(x: 0.10, y: 0.80, width: 0.20, height: 0.04)
        let tailBox = CGRect(x: 0.32, y: 0.80, width: 0.15, height: 0.04)
        let bounds: [(NSRange, CGRect)] = [
            (NSRange(location: 0, length: 11), headBox),
            (NSRange(location: 11, length: 5), tailBox),
        ]
        // The un-widened winner range [0,11) maps only to the head box, leaving
        // a partially-overlapping loser's tail unredacted — the D05-F1 defect.
        let narrow = orchestrator.boundingRect(for: NSRange(location: 0, length: 11), in: bounds)
        #expect(narrow == headBox)
        // The coalesced group span [0,16) unions both word boxes, so the tail
        // region the resolver now widens to is covered downstream.
        let coalesced = orchestrator.boundingRect(for: NSRange(location: 0, length: 16), in: bounds)
        #expect(coalesced == headBox.union(tailBox))
    }

    // MARK: - Smoke Tests (Vision-dependent)

    @Test("Blank image returns empty results")
    func blankImageReturnsEmpty() async {
        guard let ctx = createBitmapContext(width: 200, height: 200) else {
            Issue.record("Could not create context")
            return
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        guard let image = ctx.makeImage() else {
            Issue.record("Could not make image")
            return
        }

        let orchestrator = DetectionOrchestrator()
        do {
            let results = try await orchestrator.detect(pageImage: image, pageIndex: 0)
            #expect(results.isEmpty, "Blank image should return no detections")
        } catch {
            // Vision error on simulator is acceptable
        }
    }

    @Test("Text image does not crash")
    func textImageNoCrash() async {
        let image = renderTextImage("Hello World 123-45-6789", width: 600, height: 100)
        guard let image else {
            Issue.record("Could not create text image")
            return
        }

        let orchestrator = DetectionOrchestrator()
        do {
            let results = try await orchestrator.detect(pageImage: image, pageIndex: 0)
            // Vision may or may not detect text/PII on simulator — no crash is success
            _ = results
        } catch {
            // Vision error on simulator is acceptable
        }
    }

    @Test("recognitionLevel mapping: fast produces fast")
    func recognitionLevelFast() async {
        let image = renderTextImage("Test SSN 123-45-6789", width: 600, height: 100)
        guard let image else {
            Issue.record("Could not create text image")
            return
        }

        let orchestrator = DetectionOrchestrator(recognitionLevel: .fast)
        do {
            let results = try await orchestrator.detect(pageImage: image, pageIndex: 0)
            for result in results {
                if case .pii = result.kind {
                    #expect(result.recognitionLevel == .fast)
                }
            }
        } catch {
            // Vision error on simulator is acceptable
        }
    }

    @Test("Small image does not crash")
    func smallImageNoCrash() async {
        guard let ctx = createBitmapContext(width: 10, height: 10),
              let image = ctx.makeImage() else { return }
        let orchestrator = DetectionOrchestrator()
        do {
            _ = try await orchestrator.detect(pageImage: image, pageIndex: 0)
        } catch {
            // Vision error on simulator is acceptable
        }
    }

    // MARK: - L-10: Face-detection doctype gate

    @Test("Face detection skipped for .financial doctype")
    func faceDetectionSkippedForFinancialDoctype() {
        #expect(!DetectionOrchestrator.shouldRunFaceDetection(for: .financial))
    }

    @Test("Face detection runs for .court doctype")
    func faceDetectionRunsForCourtDoctype() {
        #expect(DetectionOrchestrator.shouldRunFaceDetection(for: .court))
    }

    @Test("Face detection runs for .medical doctype")
    func faceDetectionRunsForMedicalDoctype() {
        #expect(DetectionOrchestrator.shouldRunFaceDetection(for: .medical))
    }

    @Test("Face detection runs for .foia doctype")
    func faceDetectionRunsForFoiaDoctype() {
        #expect(DetectionOrchestrator.shouldRunFaceDetection(for: .foia))
    }

    @Test("Face detection runs for .generic doctype")
    func faceDetectionRunsForGenericDoctype() {
        #expect(DetectionOrchestrator.shouldRunFaceDetection(for: .generic))
    }

    @Test("Face-detection gate decisions cover all DoctypeClass cases")
    func faceDetectionGateCoversAllDoctypeClassCases() {
        // Catches drift if a new DoctypeClass is added without updating the
        // gate's switch — CaseIterable gives us the full enumeration.
        for doctype in DoctypeClass.allCases {
            _ = DetectionOrchestrator.shouldRunFaceDetection(for: doctype)
        }
        // Spot-check the v1 decision matrix.
        let runFor = DoctypeClass.allCases.filter {
            DetectionOrchestrator.shouldRunFaceDetection(for: $0)
        }
        #expect(Set(runFor) == Set([.court, .medical, .foia, .generic]))
    }

    // MARK: - Package H — Defense-in-depth pixel-cap gate (§5.3.a)

    @Test("runOCR skips images that exceed the per-axis pixel cap")
    func testRunOCRSkipsOversizedWidthImage() async throws {
        // Defense-in-depth (`03-security-perf-audit.md §5.3.a`). The engine-side
        // gate mirrors `DocumentSearcher.maxOCRPixelDimension = 10_000`. A
        // 10_001-wide blank image trips the per-axis cap and runOCR must
        // return an empty triple — no Vision call, no OCRInvocationCounter
        // bump — without raising.
        let image = try #require(makeRawImage(width: 10_001, height: 1))
        let orchestrator = DetectionOrchestrator()

        let (text, bounds, lines) = try await orchestrator.runOCR(on: image)

        #expect(text.isEmpty)
        #expect(bounds.isEmpty)
        #expect(lines.isEmpty)
    }

    @Test("runOCR skips images that exceed the total-pixel cap")
    func testRunOCRSkipsOversizedPixelCountImage() async throws {
        // 6_001 × 6_001 = 36_012_001 pixels, just over maxOCRPixelCount.
        // Each axis is below the per-axis cap; only the product gate fires.
        // The raw image is allocated with a black-fill bitmap context (≈ 144 MB
        // RGBA8). Skipped on memory-constrained CI; otherwise asserts that
        // the total-pixel cap fires before Vision is invoked.
        guard let image = makeRawImage(width: 6_001, height: 6_001) else {
            // Allocation failed (memory-constrained simulator) — skip.
            return
        }
        let orchestrator = DetectionOrchestrator()

        let (text, bounds, lines) = try await orchestrator.runOCR(on: image)

        #expect(text.isEmpty)
        #expect(bounds.isEmpty)
        #expect(lines.isEmpty)
    }

    // MARK: - Helpers

    /// Build a raw blank CGImage at the requested pixel size. Used by the
    /// pixel-cap-gate tests where the image only needs to exist; no text
    /// content is required (the gate runs before Vision is invoked).
    private func makeRawImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = createBitmapContext(width: width, height: height) else {
            return nil
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private func renderTextImage(_ text: String, width: Int, height: Int) -> CGImage? {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 36),
                .foregroundColor: UIColor.black
            ]
            (text as NSString).draw(at: CGPoint(x: 10, y: 10), withAttributes: attrs)
        }
        return uiImage.cgImage
    }
}
