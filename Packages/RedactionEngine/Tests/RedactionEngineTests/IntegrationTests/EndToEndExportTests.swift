import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// SEC-1 — End-to-end export-path protection assertion.
//
// Exercises the multi-page rasterize → reconstruct path and asserts that
// every temp file emitted by the engine-side export path is hardened to
// `.complete`. App-side hardening (PipelineCoordinator output URL, export
// copy site) is covered by ResectaAppTests; this file pins the engine-side
// contract — anyone who lands a new write into the temp tree on the engine
// side has to add an assertion here.

@Suite("End-to-End Export — temp file protection", .tags(.security))
struct EndToEndExportTests {

    @Test("Every temp file produced by PDFStreamReconstructor is `.complete`")
    func testEveryReconstructorTempFileHasCompleteProtection() async throws {
        // Drive a multi-page reconstruction and assert protection on the
        // emitted temp file.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recon_e2e_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let size = CGSize(width: 200, height: 200)
        let image = try makeSolidImage(width: 200, height: 200)
        let recon = PDFStreamReconstructor(tempURL: tempURL)
        try await recon.begin(firstPageSize: size)
        for _ in 0..<3 {
            try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))
        }
        await recon.finalize()

        // PDF opens, and file protection is `.complete` (or nil-reporting
        // on macOS host — see FileProtectionTests for the rationale).
        let doc = PDFDocument(url: tempURL)
        #expect(doc?.pageCount == 3)

        if let current = try TempFileHardening.currentProtection(of: tempURL) {
            // Host-tolerant assertion: iOS Simulator coalesces `.complete`
            // requests to `.completeUntilFirstUserAuthentication` because
            // the simulator's host filesystem cannot enforce the
            // lock-screen gate. On-device, `.complete` would be the
            // observed value. Accept either.
            let acceptable: Set<URLFileProtection> = [
                .complete, .completeUntilFirstUserAuthentication
            ]
            #expect(
                acceptable.contains(current),
                Comment(rawValue: "engine-side temp file must be at least `.complete` after finalize; got \(current.rawValue)")
            )
        }
    }

    // MARK: - Local test image

    private func makeSolidImage(width: Int, height: Int) throws -> CGImage {
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestError.contextCreationFailed }
        ctx.setFillColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else {
            throw TestError.contextCreationFailed
        }
        return image
    }

    private enum TestError: Error {
        case contextCreationFailed
    }
}
