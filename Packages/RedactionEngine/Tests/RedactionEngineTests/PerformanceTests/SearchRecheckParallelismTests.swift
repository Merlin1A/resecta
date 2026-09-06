import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// Page-parallel Search Re-check: results must not depend on the task-group
// width or completion order, and the raster wall is reported against the
// Layer-2 OCR wall on the same fixture (RB111-02 (g): ≤ 5× on the sim,
// device-confirmed at the hardware pass). PERF-ALONE, report-only — the
// ratio is printed, never asserted (Vision on the simulator is directional).

@Suite("Search Re-check parallelism", .tags(.performance), .serialized)
struct SearchRecheckParallelismTests {

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }

    @Test("Width 1 and width 3 yield identical outcomes; raster wall reported vs Layer-2 OCR",
          .timeLimit(.minutes(5)))
    func widthParityAndWallRatio() async throws {
        let n = 6
        var images: [CGImage] = []
        for i in 0..<n {
            // Two pages carry the word; four do not — completion order must not
            // change which pages are listed.
            let word = (i == 1 || i == 4) ? "CONFIDENTIAL" : "STATEMENT"
            images.append(try TestFixtures.renderedTextImage(word, width: 1200, height: 1500, fontSize: 130))
        }
        let (doc, url) = try await TestFixtures.imagePagesPDF(images, size: CGSize(width: 1200, height: 1500))
        defer { try? FileManager.default.removeItem(at: url) }
        let wrapped = SendablePDFDocument(doc)
        let requests = [TestFixtures.textRequest("CONFIDENTIAL")]

        // Production never mutates ocrParallelism; restore it whatever happens.
        defer { VerificationEngine.ocrParallelism = 3 }
        let clock = ContinuousClock()

        VerificationEngine.ocrParallelism = 1
        _ = await TestFixtures.recheck(wrapped, requests: requests, mode: .secureRasterization)  // warm-up
        let t1 = clock.now
        let serial = await TestFixtures.recheck(wrapped, requests: requests, mode: .secureRasterization)
        let serialWall = Self.seconds(clock.now - t1)

        VerificationEngine.ocrParallelism = 3
        let t3 = clock.now
        let parallel = await TestFixtures.recheck(wrapped, requests: requests, mode: .secureRasterization)
        let parallelWall = Self.seconds(clock.now - t3)

        // Layer-2 OCR wall on the same fixture at the production width, with a
        // covering region on every page so Layer 2 runs its full per-page OCR
        // pass (the Layer2OCRParallelismTests shape; the verdict is not the point).
        let covering = RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), source: .manual)
        var regions: [Int: [RedactionRegion]] = [:]
        for i in 0..<n { regions[i] = [covering] }
        let tL2 = clock.now
        let layer2 = await VerificationEngine().runLayer(
            .ocrCheck, outputDocument: wrapped, sourcePageCount: n, regions: regions,
            sensitiveTerms: [], pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: Array(repeating: .secureRasterization, count: n))
        let layer2Wall = Self.seconds(clock.now - tL2)

        #expect(serial.status == parallel.status)
        #expect(TestFixtures.message(of: serial.status) == TestFixtures.message(of: parallel.status))
        #expect(serial.pageReferences == parallel.pageReferences)
        #expect(serial.queryLines == parallel.queryLines)
        #expect(parallel.status == .attention(""), "both flagged pages must be found; got \(parallel.status)")
        #expect(parallel.pageReferences == [1, 4])

        let ratio = layer2Wall > 0 ? parallelWall / layer2Wall : 0
        print(String(
            format: "Search Re-check raster wall (%d pages, sim — directional): width1=%.3fs (%.2fs/page) width3=%.3fs (%.2fs/page) · Layer-2 OCR (width 3, covering regions)=%.3fs [%@] · re-check(width3)/Layer-2 = %.2f× (RB111-02 (g): sim bound 5×, device number rules)",
            n, serialWall, serialWall / Double(n), parallelWall, parallelWall / Double(n),
            layer2Wall, "\(layer2.status)", ratio))
    }
}
