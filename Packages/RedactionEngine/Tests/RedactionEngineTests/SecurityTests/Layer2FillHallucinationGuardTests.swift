import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import Vision
import CoreText
import Testing
@testable import RedactionEngine

// PART A — Layer-2 fill-hallucination verifier false positive (S1: fixtures +
// regression pair). See plans/resecta-partA-verifier-guard-2026-06-27/.
//
// Secure Rasterization paints solid, pixel-exact, `verifyFill`-proven black bars.
// Layer-2 then OCRs the rasterized output with the frozen `verificationLayer2`
// preset (`.fast`, `usesLanguageCorrection = false`, conf ≥ 0.50) and Vision
// hallucinates short tokens ("rn", "W", "IWI", "w") OUT OF the bars; their word
// boxes are ≥ `inRegionCoverageThreshold` (0.5) inside the (correct) region rect
// → `classifyPageOCR` returns `.textInRegion` → in `.secureRasterization` a FAIL
// (`VerificationEngine.swift:738`). No surviving PII is involved — a verifier
// false positive. Root cause confirmed off-device on the real PDF and on-device
// on iOS 26.4 (~/Downloads/verification-bug/DIAGNOSIS.md).
//
// This suite ships in S1 (PR #1) with NO production-code change:
//   • 3a characterization — GREEN today; documents the on-device false-positive
//     precondition and anchors the fixture's reproduction.
//   • 3b recall          — GREEN today, MUST stay green after the PR #2 guard:
//     readable ink inside a declared region still FAILs (the precision-only floor
//     — the guard must NEVER suppress a genuine in-region leak).
//   • 3c fill-only       — `.disabled` today (it FAILs on master = the bug);
//     PR #2 removes the trait once the fill-aware guard converts the false FAIL.
//
// The grayscale fill-fraction helper + embedded-image walk are reused from
// `RedactionMisplacementDiagnosisTests` Test 5 (the diagnostic stays uncommitted).
// The full-RGB `makeSecureRasterPage(...)` builders are added here for S2/S3 to
// construct chroma / edge-straddle / white-fill / thin-stroke fixtures at test
// time (no extra committed binaries). All on-device tests pin iOS 26.4.
//
// Matched-text / coordinate logging is permitted here under the synthetic-fixture
// exemption: the fixture is the redaction of the fully synthetic resecta-sample-doc
// statement (the "DELIA HARTWELL" corpus identity) — no real PII. Production
// logging rules (ARCH §12.2) are unchanged.

@Suite("Part A — Layer-2 fill-hallucination guard", .serialized)
struct Layer2FillHallucinationGuardTests {

    // MARK: - committed regions (the painted bar rects for the output-only fixture)

    private struct RegionsFile: Decodable {
        struct Rect: Decodable { let x: Double; let y: Double; let width: Double; let height: Double }
        let pages: [[Rect]]
    }

    /// Decode `secureraster-fill-hallucination-regions.json` into the engine's
    /// per-page region map (0-indexed; normalized bottom-left). The fixture is
    /// output-only, so Layer-2's `regions:` argument is supplied from these.
    static func committedRegions() throws -> [Int: [RedactionRegion]] {
        let data = try TestFixtures.fillHallucinationRegionsJSON()
        let file = try JSONDecoder().decode(RegionsFile.self, from: data)
        var out: [Int: [RedactionRegion]] = [:]
        for (page, rects) in file.pages.enumerated() {
            out[page] = rects.map {
                RedactionRegion(
                    id: UUID(),
                    normalizedRect: CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height),
                    source: .manual)
            }
        }
        return out
    }

    // MARK: - Test 3a — characterization (GREEN today; on-device)

    /// The permanent successor to diagnostic Test 5. OCRs each embedded page image
    /// of the real output with the frozen preset and counts per-page word boxes
    /// ≥ 50 % fill (the `classifyPageOCR` in-region drivers). Asserts the
    /// false-positive precondition — `(page2 ≥ 1 || page3 ≥ 1)` in-region drivers
    /// AND `page1 == 0` — AND the §2e faithfulness property that every driver box
    /// is ≥ 0.5 inside a committed region rect (so regions.json represents the
    /// bars). Passes on master; keeps the fixture honest. Pin iOS 26.4.
    @Test("3a. Vision hallucinates readable tokens on the solid fill bars → in-region FAIL driver (pin iOS 26.4)")
    func characterization_visionHallucinatesOnFillBars_onDevice() throws {
        let data = try TestFixtures.fillHallucinationRedactedPDF()
        let provider = try #require(CGDataProvider(data: data as CFData))
        let pdf = try #require(CGPDFDocument(provider))
        let regions = try Self.committedRegions()

        var perPage: [Int: [FillDriver]] = [:]
        for i in 0..<pdf.numberOfPages {
            guard let cg = pdf.page(at: i + 1) else { continue }
            let drivers = Self.fillDrivers(cgPage: cg)
            perPage[i] = drivers
            let summary = drivers.map { "\"\($0.text)\"@\(String(format: "%.2f", $0.fill))" }.joined(separator: ", ")
            print("[FILLHALLUC-3a] page \(i + 1): \(drivers.count) word boxes ≥50% fill (in-region FAIL drivers): \(summary)")
        }
        let p1 = perPage[0]?.count ?? 0
        let p2 = perPage[1]?.count ?? 0
        let p3 = perPage[2]?.count ?? 0
        let detail = "p1=\(p1) p2=\(p2) p3=\(p3)"

        // The user's symptom is FAIL on pages 2,3 / page 1 clean. Each in-region
        // driver is a token Vision read off the solid fill — the false positive.
        #expect(p2 >= 1 || p3 >= 1,
                "Vision should hallucinate ≥1 in-region driver on page 2 or 3 of the real output (the FAIL cause). \(detail)")
        #expect(p1 == 0,
                "page 1 should carry NO in-region driver (it did not FAIL for the user). \(detail)")

        // §2e faithfulness: every fill-driver box must be ≥ 0.5 inside a committed
        // region rect (same coverage math the verifier uses). If this fails,
        // regions.json does not represent the bars the hallucinations land on.
        for (page, drivers) in perPage {
            let pageRegions = regions[page] ?? []
            for d in drivers {
                let inside = pageRegions.contains {
                    VerificationEngine.coverageFraction(of: d.box, inside: $0.normalizedRect) >= 0.5
                }
                #expect(inside,
                        "driver \"\(d.text)\" (fill \(String(format: "%.2f", d.fill))) on page \(page + 1) is not ≥0.5 inside any committed region rect — regions.json does not represent the bars")
            }
        }
    }

    // MARK: - Test 3b — recall floor (GREEN today, MUST stay green after PR #2)

    /// The recall guard for the precision-only bar. Builds a synthetic full-page
    /// raster (single embedded image, secure-raster output shape) with readable
    /// black text on white, and passes a `regions` dict whose rect covers that
    /// text WITHOUT painting a bar there — a simulated paint-miss (region declared,
    /// ink not painted). The real Layer-2 path must FAIL: readable ink inside a
    /// region is a leak. This FAILs today (correct) and MUST still FAIL after the
    /// PR #2 fill-aware guard — the proof the guard costs no recall (it may only
    /// exclude byte-exact FILL, never real ink). Pin iOS 26.4.
    @Test("3b. readable ink inside a declared region → secure-raster FAIL (recall floor; pin iOS 26.4)")
    func recall_realInkInRegion_stillFails() async throws {
        let region = CGRect(x: 0.12, y: 0.74, width: 0.70, height: 0.07)
        let (pdf, regions) = try await Self.makeSecureRasterPage(
            text: "READABLE LEAK MARKER",
            regionRects: [region],
            paintBars: false)   // simulated paint-miss: region declared, ink NOT painted

        let outDoc = try #require(PDFDocument(data: pdf))
        let engine = VerificationEngine()
        let layer2 = await engine.runLayer(
            1,
            outputDocument: SendablePDFDocument(outDoc),
            sourcePageCount: outDoc.pageCount,
            regions: regions,
            sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: Array(repeating: nil, count: outDoc.pageCount),
            perPageModes: Array(repeating: .secureRasterization, count: outDoc.pageCount))

        #expect(layer2.status.isFail,
                "readable ink inside a redacted region must FAIL secure-raster verification (recall floor) — status=\(layer2.status)")
    }

    // MARK: - Test 3c — fill-only (DISABLED today; enabled by PR #2)

    /// Loads the real output + its committed region rects and runs the real
    /// Layer-2 path. This FAILed on master before PR #2; the chroma-aware
    /// fill-consistency guard demotes the false FAIL. Demotion tier updated
    /// 2026-07-09: the fixture folds to the fill-artifact INFO note — not a
    /// FAIL, not a WARN, and not a silent clean PASS either (the note stays
    /// visible in Verification Details; suppressing it entirely is a policy
    /// change reserved to the maintainer; the measured separation table lives in
    /// `Layer2FillGuardBatteryTests`). An info-only run aggregates to overall
    /// PASS (`StatusDerivationTests` pins the aggregate rule; asserted here on
    /// the fixture run). 3a anchors that this runtime still hallucinates the
    /// drivers, so the INFO assertion here stays non-vacuous. Pin iOS 26.4.
    @Test("fill-only hallucination on correctly-redacted output demotes to the fill-artifact INFO note (Part A guard; pin iOS 26.4)")
    func fillOnlyHallucination_doesNotFail() async throws {
        let data = try TestFixtures.fillHallucinationRedactedPDF()
        let outDoc = try #require(PDFDocument(data: data))
        let regions = try Self.committedRegions()
        let engine = VerificationEngine()
        let layer2 = await engine.runLayer(
            1,
            outputDocument: SendablePDFDocument(outDoc),
            sourcePageCount: outDoc.pageCount,
            regions: regions,
            sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: Array(repeating: nil, count: outDoc.pageCount),
            perPageModes: Array(repeating: .secureRasterization, count: outDoc.pageCount))

        #expect(!layer2.status.isFail,
                "fill-only hallucination on correctly-redacted output must not FAIL (Part A guard) — status=\(layer2.status)")
        #expect(layer2.status.isInfo,
                "demotion tier: the fixture folds to the fill-artifact INFO note, not a WARN and not a clean PASS — status=\(layer2.status)")
        if case .info(let msg) = layer2.status {
            #expect(msg.contains("no readable text recovered"),
                    "the INFO note keeps the fill-artifact wording — got \(msg)")
        }
        // The demoted note never moves the masthead: a run whose only
        // non-pass layer is this INFO aggregates to overall PASS.
        #expect(VerificationEngine().aggregateStatus([layer2]) == .pass,
                "an info-only run must aggregate to overall PASS — got \(VerificationEngine().aggregateStatus([layer2]))")
    }

    // MARK: - Test 3d — searchable-page parity (2026-07-09)

    /// The identical Part-A classification runs on SEARCHABLE pages: a proven
    /// fill artifact folds to the same INFO note as on a secure-raster page
    /// (previously `classifyPageImages` re-promoted the searchable case to the
    /// in-region WARN — a painted bar is the same pixels on either mode), while
    /// a NON-proven in-region hit keeps the searchable in-region WARN. Proven
    /// arm: the real fixture (3a anchors the drivers) re-run with every page
    /// declared `.searchableRedaction`. Non-proven arm: readable ink inside a
    /// declared-but-unpainted region on a synthetic searchable-shaped page
    /// (single full-page embedded image, same as the fixture pages) must NOT
    /// demote — the in-region WARN stands. Pin iOS 26.4.
    @Test("searchable-page parity: proven fill artifact → INFO note; non-proven in-region hit keeps the WARN (pin iOS 26.4)")
    func searchablePageParity_provenFillDemotes_nonProvenWarns() async throws {
        // Proven arm — the real hallucination fixture, declared searchable.
        let data = try TestFixtures.fillHallucinationRedactedPDF()
        let outDoc = try #require(PDFDocument(data: data))
        let regions = try Self.committedRegions()
        let engine = VerificationEngine()
        let proven = await engine.runLayer(
            1,
            outputDocument: SendablePDFDocument(outDoc),
            sourcePageCount: outDoc.pageCount,
            regions: regions,
            sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: Array(repeating: nil, count: outDoc.pageCount),
            perPageModes: Array(repeating: .searchableRedaction, count: outDoc.pageCount))
        #expect(proven.status.isInfo,
                "a proven fill artifact on a searchable page folds to the same INFO note as on a secure-raster page — status=\(proven.status)")
        if case .info(let msg) = proven.status {
            #expect(msg.contains("no readable text recovered"),
                    "searchable-page demotion carries the fill-artifact wording — got \(msg)")
        }

        // Non-proven arm — readable ink in a declared region, searchable mode.
        let region = CGRect(x: 0.12, y: 0.74, width: 0.70, height: 0.07)
        let (pdf, inkRegions) = try await Self.makeSecureRasterPage(
            text: "READABLE LEAK MARKER",
            regionRects: [region],
            paintBars: false)   // region declared, ink NOT painted over
        let inkDoc = try #require(PDFDocument(data: pdf))
        let nonProven = await engine.runLayer(
            1,
            outputDocument: SendablePDFDocument(inkDoc),
            sourcePageCount: inkDoc.pageCount,
            regions: inkRegions,
            sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: Array(repeating: nil, count: inkDoc.pageCount),
            perPageModes: Array(repeating: .searchableRedaction, count: inkDoc.pageCount))
        #expect(nonProven.status.isWarn,
                "readable (non-fill-consistent) in-region ink on a searchable page keeps the in-region WARN — status=\(nonProven.status)")
        if case .warn(let msg) = nonProven.status {
            #expect(msg.contains("OCR detected text within a redacted region"),
                    "the searchable in-region WARN wording stands — got \(msg)")
        }
    }

    // MARK: - helpers: fill-driver detection (from diagnostic Test 5)

    struct FillDriver { let text: String; let fill: CGFloat; let box: CGRect }

    /// Extract the page's EMBEDDED image (exactly what `VerificationEngine`'s
    /// `extractPageImages` feeds Vision), run the frozen `verificationLayer2`
    /// preset (`.fast`, `usesLanguageCorrection = false`, conf ≥ 0.50), and return
    /// every recognized word whose box is ≥ 50 % fill (grayscale `px <= 60`) — the
    /// boxes that sit on a solid redaction bar. The box is Vision-normalized
    /// (bottom-left), i.e. the same space as `RedactionRegion.normalizedRect` for a
    /// single full-page image, so it can be coverage-tested against the regions.
    /// Synchronous; no non-Sendable `PDFPage` crosses a concurrency boundary.
    static func fillDrivers(cgPage: CGPDFPage) -> [FillDriver] {
        guard let img = embeddedOrRendered(cgPage: cgPage) else { return [] }
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        func fillFrac(_ b: CGRect) -> CGFloat {       // b is BL-normalized
            let x0 = max(0, Int(b.minX * CGFloat(w))), x1 = min(w, Int(b.maxX * CGFloat(w)))
            let y0 = max(0, Int((1 - b.maxY) * CGFloat(h))), y1 = min(h, Int((1 - b.minY) * CGFloat(h)))
            guard x1 > x0, y1 > y0 else { return 0 }
            var blk = 0, tot = 0
            for y in y0..<y1 { let rb = y * w; for x in x0..<x1 { tot += 1; if px[rb + x] <= 60 { blk += 1 } } }
            return tot > 0 ? CGFloat(blk) / CGFloat(tot) : 0
        }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast
        req.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: img).perform([req])) != nil else { return [] }
        var out: [FillDriver] = []
        for o in (req.results ?? []) where o.confidence >= 0.50 {
            guard let cand = o.topCandidates(1).first else { continue }
            let text = cand.string
            let ns = text as NSString
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { sub, wr, _, _ in
                guard let r = Range(wr, in: text), let bb = try? cand.boundingBox(for: r) else { return }
                let box = bb.boundingBox
                let bf = fillFrac(box)
                if bf >= 0.5 { out.append(FillDriver(text: sub ?? "", fill: bf, box: box)) }
            }
        }
        return out
    }

    /// The single embedded JPEG/JPEG2000 image of a secure-raster output page (the
    /// verifier's `extractPageImages` target), with a `drawPDFPage` render
    /// fallback. The empty closure has no captures, so it converts to the C
    /// function pointer `CGPDFDictionaryApplyFunction` requires.
    static func embeddedOrRendered(cgPage: CGPDFPage) -> CGImage? {
        if let dict = cgPage.dictionary {
            var res: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dict, "Resources", &res), let r = res {
                var xo: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(r, "XObject", &xo), let x = xo {
                    final class B { var img: CGImage? }
                    let b = B()
                    CGPDFDictionaryApplyFunction(x, { (_, value, info) in
                        let bb = Unmanaged<B>.fromOpaque(info!).takeUnretainedValue()
                        if bb.img != nil { return }
                        var s: CGPDFStreamRef?
                        guard CGPDFObjectGetValue(value, .stream, &s), let st = s,
                              let sd = CGPDFStreamGetDictionary(st) else { return }
                        var sp: UnsafePointer<Int8>?
                        CGPDFDictionaryGetName(sd, "Subtype", &sp)
                        guard sp.map({ String(cString: $0) }) == "Image" else { return }
                        var fmt: CGPDFDataFormat = .raw
                        guard let d = CGPDFStreamCopyData(st, &fmt) else { return }
                        if let src = CGImageSourceCreateWithData(d, nil),
                           let im = CGImageSourceCreateImageAtIndex(src, 0, nil) { bb.img = im }
                    }, Unmanaged.passUnretained(b).toOpaque())
                    if let im = b.img { return im }
                }
            }
        }
        let cropBox = cgPage.getBoxRect(.cropBox)
        let scale: CGFloat = 300.0 / 72.0
        let w = Int((cropBox.width * scale).rounded()), h = Int((cropBox.height * scale).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(cgPage)
        return ctx.makeImage()
    }

    // MARK: - helpers: synthetic full-RGB secure-raster page builder (for S2/S3)

    /// Build a one-page PDF whose single full-page embedded image (the secure-raster
    /// output shape) renders `text` over `backgroundColor`, optionally painting
    /// solid `fillColor` bars, and return it with a matching `regions` map. Full
    /// RGB so S2/S3 can construct chroma (coloured ink/fill), edge-straddle (paint
    /// `barRects` offset from the declared `regionRects`), white-fill, and
    /// thin-stroke (pass a thin `font`) fixtures at test time.
    ///
    /// - `paintBars`: paint solid bars (over `barRects` if given, else `regionRects`).
    ///   Pass `false` for a paint-miss (readable ink left inside a declared region).
    /// - The image is embedded through the production `PDFStreamReconstructor`
    ///   (JPEG q0.92, single image XObject) so the verifier's `extractPageImages`
    ///   finds it and `coordinatesTrusted` holds (images.count == 1).
    /// - `text` is laid into the first region rect (or a default band if none);
    ///   `textRect` overrides the placement (S3 battery — straddle geometry).
    /// - `textOverBars: true` draws the text AFTER the bars (S3 battery — ink ON
    ///   a painted bar: chroma / thin / pale / reverse-video probes).
    /// - `strokeWidth` (CoreText convention: percent of font size, positive =
    ///   stroke-ONLY) renders knockout/outline glyphs whose body is unpainted —
    ///   the bar shows through (S3 battery — F-REVERSE-VIDEO). `strokeColor`
    ///   defaults to `textColor`.
    static func makeSecureRasterPage(
        text: String,
        textColor: CGColor = CGColor(gray: 0, alpha: 1),
        fillColor: CGColor = CGColor(gray: 0, alpha: 1),
        backgroundColor: CGColor = CGColor(gray: 1, alpha: 1),
        regionRects: [CGRect],
        paintBars: Bool,
        barRects: [CGRect]? = nil,
        font: CTFont? = nil,
        pageSize: CGSize = CGSize(width: 612, height: 792),
        dpi: CGFloat = 200,
        textRect: CGRect? = nil,
        textOverBars: Bool = false,
        strokeWidth: CGFloat? = nil,
        strokeColor: CGColor? = nil
    ) async throws -> (pdf: Data, regions: [Int: [RedactionRegion]]) {
        let wPx = Int((pageSize.width * dpi / 72).rounded())
        let hPx = Int((pageSize.height * dpi / 72).rounded())
        // CGContext bitmaps are bottom-left origin — the same space as
        // RedactionRegion.normalizedRect — so no y-flip is needed anywhere here.
        func toPx(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * CGFloat(wPx), y: r.minY * CGFloat(hPx),
                   width: r.width * CGFloat(wPx), height: r.height * CGFloat(hPx))
        }

        guard let ctx = CGContext(
            data: nil, width: wPx, height: hPx, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw FillPageError.imageRenderFailed }

        ctx.setFillColor(backgroundColor)
        ctx.fill(CGRect(x: 0, y: 0, width: wPx, height: hPx))

        let target = (textRect ?? regionRects.first).map(toPx)
            ?? CGRect(x: CGFloat(wPx) * 0.1, y: CGFloat(hPx) * 0.82,
                      width: CGFloat(wPx) * 0.8, height: CGFloat(hPx) * 0.08)
        if !textOverBars {
            Self.drawText(text, in: target, color: textColor, font: font,
                          strokeWidth: strokeWidth, strokeColor: strokeColor, context: ctx)
        }

        if paintBars {
            ctx.setFillColor(fillColor)
            for r in (barRects ?? regionRects) { ctx.fill(toPx(r)) }
        }

        if textOverBars {
            Self.drawText(text, in: target, color: textColor, font: font,
                          strokeWidth: strokeWidth, strokeColor: strokeColor, context: ctx)
        }

        guard let image = ctx.makeImage() else { throw FillPageError.imageRenderFailed }

        // Embed through the production reconstructor (JPEG q0.92, single image
        // XObject) so the verifier's extractPageImages finds it and
        // coordinatesTrusted holds (images.count == 1).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fillhalluc-\(UUID().uuidString).pdf")
        let reconstructor = PDFStreamReconstructor(tempURL: tmp)
        try await reconstructor.begin(firstPageSize: pageSize)
        try await reconstructor.appendPage(PageOutput(image: image, size: pageSize, textLayerEntries: nil))
        await reconstructor.finalize()
        let pdf = try Data(contentsOf: tmp)
        try? FileManager.default.removeItem(at: tmp)

        let regions: [Int: [RedactionRegion]] = [
            0: regionRects.map { RedactionRegion(id: UUID(), normalizedRect: $0, source: .manual) }
        ]
        return (pdf, regions)
    }

    enum FillPageError: Error { case imageRenderFailed }

    /// Draw `text` to fit inside `rect` (CG bottom-left pixels) via CoreText, into
    /// `ctx`. Sizes the font to fit the rect width and seats the baseline so the
    /// glyphs land within the rect (so the OCR word boxes are ≥ 0.5 inside it).
    /// `strokeWidth`/`strokeColor` map to the CoreText stroke attributes (percent
    /// of font size; positive = stroke-only outline glyphs — S3 battery).
    private static func drawText(_ text: String, in rect: CGRect, color: CGColor, font: CTFont?,
                                 strokeWidth: CGFloat? = nil, strokeColor: CGColor? = nil,
                                 context ctx: CGContext) {
        func makeFont(_ s: CGFloat) -> CTFont {
            if let font { return CTFontCreateCopyWithAttributes(font, s, nil, nil) }
            return CTFontCreateWithName("Helvetica-Bold" as CFString, s, nil)
        }
        func makeLine(_ ctFont: CTFont) -> CTLine {
            var attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ]
            if let strokeWidth {
                attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = strokeWidth
                attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = strokeColor ?? color
            }
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        }
        var size = rect.height * 0.72
        var line = makeLine(makeFont(size))
        let maxWidth = Double(rect.width * 0.96)
        let measured = CTLineGetTypographicBounds(line, nil, nil, nil)
        if measured > maxWidth, measured > 0 {
            size *= CGFloat(maxWidth / measured)
            line = makeLine(makeFont(size))
        }
        ctx.textPosition = CGPoint(x: rect.minX + rect.width * 0.02, y: rect.minY + rect.height * 0.28)
        CTLineDraw(line, ctx)
    }

    // MARK: - Part A pure unit tests — the guard's predicate (no Vision / no sim)

    private static func manualRegion(_ r: CGRect) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: r, source: .manual)
    }
    private static func sample(_ fill: CGFloat, _ contrast: CGFloat, _ maxDev: CGFloat) -> VerificationEngine.BoxFillSample {
        VerificationEngine.BoxFillSample(fillFraction: fill, contrastFraction: contrast, maxDeviation: maxDev)
    }

    @Test("isFillConsistent: overwhelming fill, no contrast, small outlier → demote candidate")
    func isFillConsistent_fill() {
        #expect(VerificationEngine.isFillConsistent(Self.sample(0.99, 0.0, 0.05)))
    }
    @Test("isFillConsistent: recall floor — readable contrast is NEVER excluded (regardless of fill)")
    func isFillConsistent_recallFloor() {
        // 20% contrast (e.g. readable white-on-bar strokes) — KEPT.
        #expect(!VerificationEngine.isFillConsistent(Self.sample(0.95, 0.20, 0.9)))
    }
    @Test("isFillConsistent: outlier floor — a single strong-ink pixel (thin glyph core) is NEVER excluded")
    func isFillConsistent_outlierFloor() {
        #expect(!VerificationEngine.isFillConsistent(Self.sample(0.99, 0.0, 0.85)))
    }
    @Test("isFillConsistent: below the fill floor is not a demotion candidate")
    func isFillConsistent_belowFillFloor() {
        #expect(!VerificationEngine.isFillConsistent(Self.sample(0.80, 0.0, 0.05)))
    }

    // MARK: - Part A pure unit tests — the classifier fold over synthetic boxFill

    @Test("classifyPageOCR: a fill-consistent in-region box → fillArtifactInRegion (demoted, NOT a clean PASS)")
    func classifyPageOCR_fillArtifactDemoted() {
        let region = Self.manualRegion(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let h = VerificationEngine.OCRHit(box: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1),
                                          wordBoxes: [], text: "rn", confidence: 0.9,
                                          boxFill: [Self.sample(0.99, 0.0, 0.04)])
        let verdict = VerificationEngine.classifyPageOCR(hits: [h], pageRegions: [region], sensitiveTerms: [])
        #expect(verdict == .fillArtifactInRegion, "fill-consistent hallucination must demote, not FAIL")
        #expect(verdict != .none, "demote-never-silence: an in-region box must never fold to a clean PASS")
    }
    @Test("classifyPageOCR: recall floor — readable in-region ink stays textInRegion (FAIL driver kept)")
    func classifyPageOCR_recallFloorKept() {
        let region = Self.manualRegion(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let h = VerificationEngine.OCRHit(box: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1),
                                          wordBoxes: [], text: "LEAK", confidence: 0.9,
                                          boxFill: [Self.sample(0.80, 0.20, 0.95)])
        #expect(VerificationEngine.classifyPageOCR(hits: [h], pageRegions: [region], sensitiveTerms: []) == .textInRegion)
    }
    @Test("classifyPageOCR: outlier floor — one strong-ink pixel keeps the box (textInRegion)")
    func classifyPageOCR_outlierFloorKept() {
        let region = Self.manualRegion(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let h = VerificationEngine.OCRHit(box: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1),
                                          wordBoxes: [], text: "x", confidence: 0.9,
                                          boxFill: [Self.sample(0.98, 0.0, 0.85)])
        #expect(VerificationEngine.classifyPageOCR(hits: [h], pageRegions: [region], sensitiveTerms: []) == .textInRegion)
    }
    @Test("classifyPageOCR: empty boxFill behaves exactly as before (in-region → textInRegion)")
    func classifyPageOCR_emptyBoxFillUnchanged() {
        let region = Self.manualRegion(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let h = VerificationEngine.OCRHit(box: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1),
                                          wordBoxes: [], text: "x", confidence: 0.9)   // boxFill defaults []
        #expect(VerificationEngine.classifyPageOCR(hits: [h], pageRegions: [region], sensitiveTerms: []) == .textInRegion)
    }
    @Test("classifyPageOCR: a fill artifact does NOT FAIL even if its text matches a term (no readable ink)")
    func classifyPageOCR_fillArtifactWithTermDoesNotFail() {
        let region = Self.manualRegion(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let h = VerificationEngine.OCRHit(box: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1),
                                          wordBoxes: [], text: "SSN", confidence: 0.99,
                                          boxFill: [Self.sample(0.99, 0.0, 0.03)])
        #expect(VerificationEngine.classifyPageOCR(hits: [h], pageRegions: [region], sensitiveTerms: ["ssn"]) == .fillArtifactInRegion,
                "a hallucinated term off the solid bar carries no readable ink → not a term FAIL")
    }
    @Test("classifyPageOCR: a demoted in-region box never silences a sibling out-of-region box (straddle)")
    func classifyPageOCR_demoteNeverSilencesSibling() {
        let region = Self.manualRegion(CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20))
        let h = VerificationEngine.OCRHit(
            box: CGRect(x: 0.10, y: 0.40, width: 0.80, height: 0.20),
            wordBoxes: [CGRect(x: 0.42, y: 0.42, width: 0.16, height: 0.16),    // inside region (fill)
                        CGRect(x: 0.05, y: 0.80, width: 0.15, height: 0.05)],   // outside region (ink)
            text: "x", confidence: 0.9,
            boxFill: [Self.sample(0.99, 0.0, 0.03), Self.sample(0.0, 1.0, 1.0)])
        let verdict = VerificationEngine.classifyPageOCR(hits: [h], pageRegions: [region], sensitiveTerms: [])
        #expect(verdict == .fillArtifactInRegion, "WARN — never a clean PASS")
        #expect(verdict != .none)
    }

    // MARK: - Part A pure unit tests — boxFillSample pixel math (hand-built BGRA)

    /// A tightly-packed BGRA buffer (bytesPerRow = width*4), filled with `bg`, with
    /// the first `inkRows` rows overwritten by `ink`. Colours are (r,g,b), 0…255.
    private static func bgra(width: Int, height: Int,
                             bg: (r: UInt8, g: UInt8, b: UInt8),
                             ink: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0),
                             inkRows: Int = 0) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let c = y < inkRows ? ink : bg
            for x in 0..<width {
                let off = (y * width + x) * 4
                buf[off + 0] = c.b; buf[off + 1] = c.g; buf[off + 2] = c.r; buf[off + 3] = 255
            }
        }
        return buf
    }
    private static func wholeBoxSample(_ buf: [UInt8], _ w: Int, _ h: Int,
                                       fill: (r: CGFloat, g: CGFloat, b: CGFloat)) -> VerificationEngine.BoxFillSample {
        buf.withUnsafeBufferPointer {
            VerificationEngine.boxFillSample(box: CGRect(x: 0, y: 0, width: 1, height: 1),
                rgba: $0.baseAddress!, width: w, height: h, bytesPerRow: w * 4, fill: fill)
        }
    }

    @Test("boxFillSample: a solid black bar is fill-consistent")
    func boxFillSample_solidBlack() {
        let s = Self.wholeBoxSample(Self.bgra(width: 10, height: 10, bg: (0, 0, 0)), 10, 10, fill: (0, 0, 0))
        #expect(s.fillFraction == 1.0)
        #expect(s.contrastFraction == 0.0)
        #expect(VerificationEngine.isFillConsistent(s))
    }
    @Test("boxFillSample: black bar + white glyph stripe is KEPT (readable contrast)")
    func boxFillSample_blackWithWhiteStripe() {
        let s = Self.wholeBoxSample(Self.bgra(width: 10, height: 10, bg: (0, 0, 0), ink: (255, 255, 255), inkRows: 2), 10, 10, fill: (0, 0, 0))
        #expect(s.contrastFraction >= 0.10)
        #expect(!VerificationEngine.isFillConsistent(s))
    }
    @Test("boxFillSample: white bar + black glyph is KEPT, and a solid white bar is fill-consistent (symmetry)")
    func boxFillSample_whiteFillSymmetry() {
        let glyph = Self.wholeBoxSample(Self.bgra(width: 10, height: 10, bg: (255, 255, 255), ink: (0, 0, 0), inkRows: 2), 10, 10, fill: (1, 1, 1))
        #expect(glyph.contrastFraction >= 0.10)
        #expect(!VerificationEngine.isFillConsistent(glyph))
        let solid = Self.wholeBoxSample(Self.bgra(width: 10, height: 10, bg: (255, 255, 255)), 10, 10, fill: (1, 1, 1))
        #expect(VerificationEngine.isFillConsistent(solid))
    }
    @Test("boxFillSample: a BLUE glyph whose luminance ≈ the black fill is KEPT (chroma-aware, not luminance)")
    func boxFillSample_blueGlyphChroma() {
        // Blue (0,0,115): Rec.601 luma ≈ 0.114·0.451 ≈ 0.051 — INSIDE the fill band,
        // so a luminance-only guard would call it fill and wrongly demote. Full-RGB
        // sees the B-channel deviation (0.451) as contrast. 2 rows = 20% coverage.
        let s = Self.wholeBoxSample(Self.bgra(width: 10, height: 10, bg: (0, 0, 0), ink: (0, 0, 115), inkRows: 2), 10, 10, fill: (0, 0, 0))
        let blueLuma = 0.299 * 0.0 + 0.587 * 0.0 + 0.114 * (115.0 / 255.0)
        #expect(blueLuma < 0.16, "the blue's luminance must sit inside the fill band (the chroma trap a luminance-only guard falls into)")
        #expect(s.contrastFraction >= 0.10, "full-RGB sampling reads the hue deviation as contrast")
        #expect(!VerificationEngine.isFillConsistent(s), "chroma-aware guard KEEPS coloured ink that luminance would have demoted")
    }

    // MARK: - Part A measurement (on-device, pin iOS 26.4) — §4 fixture fractions

    /// OCR a secure-raster page and return every word box ≥ 0.5 inside `region`
    /// (no fill filter — used for the recall raster, whose ink is NOT ≥ 50 % fill).
    /// Internal (not private) so the S3 battery suite reuses it.
    static func inRegionOCRBoxes(cgPage: CGPDFPage, region: CGRect) -> [(text: String, box: CGRect)] {
        guard let img = embeddedOrRendered(cgPage: cgPage) else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast
        req.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: img).perform([req])) != nil else { return [] }
        var out: [(String, CGRect)] = []
        for o in (req.results ?? []) where o.confidence >= 0.50 {
            guard let cand = o.topCandidates(1).first else { continue }
            let text = cand.string; let ns = text as NSString
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { sub, wr, _, _ in
                guard let r = Range(wr, in: text), let bb = try? cand.boundingBox(for: r) else { return }
                let box = bb.boundingBox
                if VerificationEngine.coverageFraction(of: box, inside: region) >= 0.5 { out.append((sub ?? "", box)) }
            }
        }
        return out
    }

    /// Measures, through the PRODUCTION sampler (`enrichWithFillSamples`), the
    /// full-RGB (fillFraction, contrastFraction, maxDeviation) for every real
    /// in-region hallucination driver on pages 2 & 3 of the fixture (must be
    /// fill-consistent ⇒ the guard demotes the false FAIL) AND for the readable ink
    /// in the recall raster's declared region (must NOT be fill-consistent ⇒ the
    /// precision-only floor). Printed fractions are recorded in the PR body (§4).
    @Test("measure: real fill-hallucination drivers are fill-consistent; recall ink is KEPT (pin iOS 26.4)")
    func measure_fillConsistency_onDevice() async throws {
        let data = try TestFixtures.fillHallucinationRedactedPDF()
        let provider = try #require(CGDataProvider(data: data as CFData))
        let pdf = try #require(CGPDFDocument(provider))
        let regions = try Self.committedRegions()

        var driverCount = 0
        var allDriversConsistent = true
        var report = "\n"
        for pageIdx in [1, 2] {   // pages 2,3 (0-indexed) carry the in-region drivers
            guard let cg = pdf.page(at: pageIdx + 1),
                  let image = Self.embeddedOrRendered(cgPage: cg) else { continue }
            let drivers = Self.fillDrivers(cgPage: cg)
            let hits = drivers.map { VerificationEngine.OCRHit(box: $0.box, wordBoxes: [], text: $0.text, confidence: 0.9) }
            let enriched = VerificationEngine.enrichWithFillSamples(hits, image: image, regions: regions[pageIdx] ?? [])
            for (d, h) in zip(drivers, enriched) {
                guard let s = h.boxFill.first else { continue }
                driverCount += 1
                let consistent = VerificationEngine.isFillConsistent(s)
                allDriversConsistent = allDriversConsistent && consistent
                let line = String(format: "[FILLHALLUC-S2] page %d \"%@\" fill=%.3f contrast=%.3f maxDev=%.3f → %@",
                                  pageIdx + 1, d.text, s.fillFraction, s.contrastFraction, s.maxDeviation,
                                  consistent ? "FILL-CONSISTENT (demote)" : "KEPT")
                print(line); report += line + "\n"
            }
        }
        #expect(driverCount >= 1, "the measurement must see ≥1 real in-region driver on 26.4 (non-vacuous)")
        #expect(allDriversConsistent, "every real in-region fill-hallucination driver must be fill-consistent → the guard demotes the false FAIL\(report)")

        // Recall side: readable ink in a declared-but-unpainted region must NOT be
        // fill-consistent (the precision-only floor). Sampled via the same path.
        let region = CGRect(x: 0.12, y: 0.74, width: 0.70, height: 0.07)
        let (recallPDF, recallRegions) = try await Self.makeSecureRasterPage(
            text: "READABLE LEAK MARKER", regionRects: [region], paintBars: false)
        let recallProvider = try #require(CGDataProvider(data: recallPDF as CFData))
        let recallDoc = try #require(CGPDFDocument(recallProvider))
        let cg = try #require(recallDoc.page(at: 1))
        let image = try #require(Self.embeddedOrRendered(cgPage: cg))
        let inkBoxes = Self.inRegionOCRBoxes(cgPage: cg, region: region)
        let inkHits = inkBoxes.map { VerificationEngine.OCRHit(box: $0.box, wordBoxes: [], text: $0.text, confidence: 0.9) }
        let inkEnriched = VerificationEngine.enrichWithFillSamples(inkHits, image: image, regions: recallRegions[0] ?? [])
        var sawKeptInk = false
        var recallReport = "\n"
        for (b, h) in zip(inkBoxes, inkEnriched) {
            guard let s = h.boxFill.first else { continue }
            let consistent = VerificationEngine.isFillConsistent(s)
            sawKeptInk = sawKeptInk || !consistent
            let line = String(format: "[FILLHALLUC-S2] recall \"%@\" fill=%.3f contrast=%.3f maxDev=%.3f → %@",
                              b.text, s.fillFraction, s.contrastFraction, s.maxDeviation,
                              consistent ? "FILL-CONSISTENT (WRONG)" : "KEPT (correct)")
            print(line); recallReport += line + "\n"
        }
        #expect(!inkBoxes.isEmpty, "the recall raster must yield ≥1 in-region OCR box to measure (non-vacuous)")
        #expect(sawKeptInk, "readable ink in a declared region must NOT be fill-consistent (precision-only floor)\(recallReport)")
    }
}
