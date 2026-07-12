import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import RedactionEngine

// .serialized: VNImageRequestHandler.perform() blocks cooperative pool threads (F2-8).
@Suite("Face Detector", .serialized)
struct FaceDetectorTests {

    @Test("Solid-color image returns zero faces or graceful error")
    func noFaceInSolidColor() async throws {
        guard let ctx = createBitmapContext(width: 200, height: 200) else {
            Issue.record("Could not create context")
            return
        }
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        guard let image = ctx.makeImage() else { return }

        let detector = FaceDetector()
        do {
            let results = try await detector.detect(in: image)
            #expect(results.isEmpty, "Solid color should have no faces")
        } catch {
            // CAT-218: surface a Vision failure as a recorded known issue
            // instead of a silent swallow. The #expect above still runs (and is
            // enforced) when Vision is available; only a thrown Vision error —
            // expected on a simulator without a Neural Engine — lands here.
            withKnownIssue("Vision face detection unavailable on this simulator (no Neural Engine)") {
                throw error
            }
        }
    }

    @Test("Small image does not crash")
    func smallImageNoCrash() async {
        guard let ctx = createBitmapContext(width: 10, height: 10),
              let image = ctx.makeImage() else { return }
        let detector = FaceDetector()
        do {
            _ = try await detector.detect(in: image)
        } catch {
            // CAT-218: record the Vision failure as a known issue rather than
            // swallowing it — a total Vision outage now surfaces in the run.
            withKnownIssue("Vision face detection unavailable on this simulator (no Neural Engine)") {
                throw error
            }
        }
    }

    @Test("Padding math: 20% expansion with edge clamping")
    func paddingMath() {
        let face = CGRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1)
        let padded = face.insetBy(dx: -face.width * 0.2, dy: -face.height * 0.2)
        let clamped = padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(clamped.maxX <= 1.0)
        #expect(clamped.maxY <= 1.0)
        #expect(clamped.width > face.width, "Padding should expand the rect")
    }

    @Test("Detection result kind is face")
    func detectionResultKindIsFace() async {
        guard let ctx = createBitmapContext(width: 200, height: 200),
              let image = ctx.makeImage() else { return }
        let detector = FaceDetector()
        do {
            let results = try await detector.detect(in: image)
            for result in results {
                if case .face = result.kind {
                    // Expected
                } else {
                    Issue.record("Expected .face kind, got \(result.kind)")
                }
            }
        } catch {
            // CAT-218: record the Vision failure as a known issue rather than
            // swallowing it.
            withKnownIssue("Vision face detection unavailable on this simulator (no Neural Engine)") {
                throw error
            }
        }
    }

    @Test("Padding at origin clamps to zero")
    func paddingOriginClamp() {
        let face = CGRect(x: 0.0, y: 0.0, width: 0.1, height: 0.1)
        let padded = face.insetBy(dx: -face.width * 0.2, dy: -face.height * 0.2)
        let clamped = padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(clamped.minX >= 0.0)
        #expect(clamped.minY >= 0.0)
        #expect(clamped.width > face.width, "Padding should expand the rect")
    }

    @Test("Padding expands center face correctly")
    func paddingCenterFace() {
        let face = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let padded = face.insetBy(dx: -face.width * 0.2, dy: -face.height * 0.2)
        let clamped = padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(abs(clamped.minX - 0.22) < 0.01)
        #expect(abs(clamped.minY - 0.22) < 0.01)
        #expect(abs(clamped.width - 0.56) < 0.01)
        #expect(abs(clamped.height - 0.56) < 0.01)
    }

    // MARK: - CAT-068 confidence floor

    @Test("Below-floor confidence observations are dropped (CAT-068)")
    func lowConfidenceFiltered() {
        let box = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        // Below the 0.3 floor → dropped before any geometry.
        #expect(FaceDetector.normalizedPaddedRect(confidence: 0.2, boundingBox: box) == nil)
        // At the floor → retained, still carrying the §4.8 padding.
        let kept = FaceDetector.normalizedPaddedRect(confidence: 0.3, boundingBox: box)
        #expect(kept != nil)
        #expect((kept?.width ?? 0) > box.width, "Retained observation keeps the §4.8 padding")
    }

    @Test("Confidence floor constant is 0.3 (CAT-068)")
    func floorConstantValue() {
        #expect(FaceDetector.minimumFaceConfidence == 0.3)
    }

    // MARK: - CAT-218 real-face positive path

    // The detector suite has no positive-recall guard: every detect() call runs
    // on a solid-color or tiny synthetic image, so FaceDetector could regress to
    // returning zero faces on a real face and stay green (face redaction is a
    // marketed HIPAA-identifier-17 differentiator). This is that guard.
    //
    // BLOCKED-ON-ASSET: awaiting the maintainer's photo (D-19). VNDetectFaceRectanglesRequest
    // is trained on real faces — synthetic ovals/dots do not trigger it (§2.7),
    // so the fixture must be a real photo. Per D-19 it is the maintainer's OWN photo (no
    // third-party CC0 sourcing — that alternative was not selected). Until
    // Fixtures/TestResources/face_source.jpg is committed this test is .disabled;
    // the asset-independent half (the swallowing error blocks above, now
    // recorded via withKnownIssue) already landed. To enable: commit the photo,
    // drop the `.disabled` trait.
    @Test("Real face image produces at least one detection (CAT-218)",
          .disabled("BLOCKED-ON-ASSET: awaiting Jesse photo (D-19) — face_source.jpg not committed"))
    func testFaceDetectedInRealFaceImage() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "face_source", withExtension: "jpg",
                              subdirectory: "TestResources"),
            "face_source.jpg must be committed to Fixtures/TestResources (D-19)")
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("Could not decode face_source.jpg")
            return
        }
        // Vision may be unavailable on a simulator without a Neural Engine; a
        // thrown request is recorded as a known issue (isIntermittent: real
        // hardware succeeds). The recall #expect runs only on success, so a
        // zero-face result on a real face is still a hard failure.
        let detector = FaceDetector()
        var faceCount: Int?
        await withKnownIssue(
            "Vision face detection unavailable on this simulator (no Neural Engine)",
            isIntermittent: true
        ) {
            faceCount = try await detector.detect(in: image).count
        }
        if let faceCount {
            #expect(faceCount >= 1, "Real face image must produce at least one detection")
        }
    }
}
