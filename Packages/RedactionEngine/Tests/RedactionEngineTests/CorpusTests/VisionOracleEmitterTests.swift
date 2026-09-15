import Foundation
import CoreGraphics
import ImageIO
import Testing
import Vision

// H2.3 O3 (Vision leg) — an env-gated emitter the oracle runner
// (`verify_oracle.py`) drives to get Vision `.accurate` text over its own
// pdftoppm-rendered page rasters, WITHOUT adding any Mac-side dependency
// (instrumentation plan §5; the 31- §E ruling prefers the engine test target
// over a new tool). Deliberately independent of the product's `OCREngine`
// configuration: language correction OFF, a low minimum text height, and a
// pinned request revision, so the oracle is not correlated with the
// verifier's own Layer-2 settings.
//
// Contract: RESECTA_VISION_IN = a directory of .png page rasters;
// RESECTA_VISION_OUT = a directory that receives one `<stem>.json` per PNG:
// {image, lines:[{text, confidence, bbox:[x,y,w,h] normalized bottom-left}]}.
// Never in the batched gate; a plain `swift test --filter` host run drives it.

@Suite("H2.3 Vision oracle emitter (standing tool)", .serialized)
struct VisionOracleEmitterTests {

    static func env(_ key: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        if let p = env[key], !p.isEmpty { return p }
        if let p = env["TEST_RUNNER_" + key], !p.isEmpty { return p }
        return nil
    }

    struct LineRow: Encodable {
        let text: String
        let confidence: Double
        let bbox: [Double]
    }
    struct ImageReport: Encodable {
        let schema_version: Int
        let generated_by: String
        let image: String
        let request_revision: Int
        let uses_language_correction: Bool
        let minimum_text_height: Double
        let lines: [LineRow]
    }

    static func r6(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }

    @Test("Emit Vision text over the oracle's page rasters")
    func emitVisionText() throws {
        guard let inDir = Self.env("RESECTA_VISION_IN"),
              let outDir = Self.env("RESECTA_VISION_OUT") else {
            print("[H2.3-Vision] RESECTA_VISION_IN/OUT not set; emitter skipped.")
            return
        }
        try FileManager.default.createDirectory(
            atPath: outDir, withIntermediateDirectories: true)
        let pngs = try FileManager.default.contentsOfDirectory(atPath: inDir)
            .filter { $0.hasSuffix(".png") }
            .sorted()
        var emitted = 0
        for name in pngs {
            let url = URL(fileURLWithPath: inDir).appendingPathComponent(name)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                print("[H2.3-Vision] unreadable: \(name)")
                continue
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.01
            request.revision = VNRecognizeTextRequestRevision3
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            let lines: [LineRow] = (request.results ?? []).compactMap { obs in
                guard let top = obs.topCandidates(1).first else { return nil }
                let b = obs.boundingBox
                return LineRow(
                    text: top.string,
                    confidence: Self.r6(Double(top.confidence)),
                    bbox: [Self.r6(b.origin.x), Self.r6(b.origin.y),
                           Self.r6(b.width), Self.r6(b.height)])
            }
            let report = ImageReport(
                schema_version: 1,
                generated_by: "VisionOracleEmitterTests.emitVisionText",
                image: name,
                request_revision: VNRecognizeTextRequestRevision3,
                uses_language_correction: false,
                minimum_text_height: 0.01,
                lines: lines)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let stem = (name as NSString).deletingPathExtension
            try encoder.encode(report).write(
                to: URL(fileURLWithPath: outDir).appendingPathComponent("\(stem).json"),
                options: .atomic)
            emitted += 1
        }
        print("[H2.3-Vision] done: \(emitted)/\(pngs.count) rasters -> \(outDir)")
    }
}
