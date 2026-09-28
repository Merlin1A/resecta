import Foundation
import CoreGraphics
import PDFKit
import Testing
import CryptoKit
@testable import RedactionEngine

// H2.2 support (1/2): ground truth -> region sets, the two
// PipelineCoordinator mirrors (buildPDFPageData / processDocument) and the
// verification pass on the product's own `VerificationOrchestrator`. See
// VerificationCorpusRunnerTests.swift for the suite header and the
// mirroring-risk note.

extension VerificationCorpusRunnerTests {

    // MARK: - Ground truth

    struct GTSpan: Decodable {
        let page: Int
        let bbox: [Double]?
    }
    struct GTOccurrence: Decodable {
        let id: String
        let value: String
        let category: String
        let page: Int?
        let bbox: [Double]?          // [x0, y0, x1, y1] normalized, bottom-left
        let expectation: String
        let spans: [GTSpan]?
    }
    struct GTFile: Decodable {
        let occurrences: [GTOccurrence]
        let carried_stmt: [GTOccurrence]?
    }

    /// One drawable region candidate derived from GT.
    struct RegionSeed {
        let gtId: String
        let value: String
        let category: String
        let page: Int
        let rect: CGRect             // normalized [x, y, w, h], bottom-left
    }

    static func regionSeeds(from gt: GTFile) -> [RegionSeed] {
        var seeds: [RegionSeed] = []
        for occ in gt.occurrences where occ.expectation == "must_fire" {
            // Multi-span occurrences contribute one region per span; the
            // single-box common case falls out of `spans` carrying one entry
            // mirroring `bbox`.
            let spans: [(Int, [Double])]
            if let s = occ.spans, !s.isEmpty {
                spans = s.compactMap { sp in sp.bbox.map { (sp.page, $0) } }
            } else if let page = occ.page, let bbox = occ.bbox {
                spans = [(page, bbox)]
            } else {
                spans = []
            }
            for (page, b) in spans where b.count == 4 {
                seeds.append(RegionSeed(
                    gtId: occ.id, value: occ.value, category: occ.category,
                    page: page,
                    rect: CGRect(x: b[0], y: b[1],
                                 width: b[2] - b[0], height: b[3] - b[1])))
            }
        }
        return seeds
    }

    // MARK: - Region sets

    /// Deterministic PRNG (SplitMix64) so `seeded-subset` is reproducible
    /// without Foundation randomness.
    struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    static let subsetK = 12
    static let subsetSeed: UInt64 = 20_260_823

    struct RegionSetSpec {
        let name: String
        let seeds: [RegionSeed]
        let polygon: Bool
        let params: [String: Int]?
    }

    static func regionSets(for seeds: [RegionSeed]) -> [RegionSetSpec] {
        let ordered = seeds.sorted {
            ($0.gtId, $0.page) < ($1.gtId, $1.page)
        }
        var rng = SplitMix64(seed: subsetSeed)
        let k = min(subsetK, ordered.count)
        let subset = Array(ordered.shuffled(using: &rng).prefix(k))
            .sorted { ($0.gtId, $0.page) < ($1.gtId, $1.page) }
        return [
            RegionSetSpec(name: "all-must-fire", seeds: ordered,
                          polygon: false, params: nil),
            RegionSetSpec(name: "seeded-subset", seeds: subset,
                          polygon: false,
                          params: ["k": k, "seed": Int(subsetSeed)]),
            RegionSetSpec(name: "polygon", seeds: ordered,
                          polygon: true, params: nil),
        ]
    }

    /// GT rect -> RedactionRegion, mirroring `buildPDFPageData`'s minimum
    /// dimension floor and clamp (`PipelineCoordinator.buildPDFPageData`).
    /// Returns nil for a below-floor box so the caller can record the drop.
    static func region(from seed: RegionSeed, polygon: Bool) -> RedactionRegion? {
        guard seed.rect.width > 0.001, seed.rect.height > 0.001 else { return nil }
        let clamped = seed.rect.clampedToNormalized()
        let vertices: [CGPoint]? = polygon ? [
            CGPoint(x: clamped.minX, y: clamped.minY),
            CGPoint(x: clamped.maxX, y: clamped.minY),
            CGPoint(x: clamped.maxX, y: clamped.maxY),
            CGPoint(x: clamped.minX, y: clamped.maxY),
        ] : nil
        return RedactionRegion(
            id: UUID(), normalizedRect: clamped, source: .manual,
            vertices: vertices)
    }

    /// Sensitive terms for the burned regions, mirroring the app's
    /// `PipelineCoordinator.sensitiveTerms(fromAppliedRegions:metadata:audit:)`
    /// contribution for detection-applied regions: the matched text of every
    /// burned region, with token-boundary matching for a bare single-word
    /// name token. The app's typed-query contribution reads the applied
    /// record on the audit (a text query as typed; a multi-term row's term;
    /// a regex or a Scan nothing beyond the matched text); the corpus seeds
    /// carry no record, so this is the whole rule here.
    static func sensitiveTerms(for seeds: [RegionSeed]) -> [SensitiveTerm] {
        var boundaryByText: [String: Bool] = [:]
        for seed in seeds where !seed.value.isEmpty {
            let singleTokenName = seed.category == "name"
                && seed.value.split(whereSeparator: { $0.isWhitespace }).count <= 1
            // Boundary only when EVERY contribution wants it (matches the
            // app's insert(): plain substring wins on conflict).
            if let existing = boundaryByText[seed.value] {
                boundaryByText[seed.value] = existing && singleTokenName
            } else {
                boundaryByText[seed.value] = singleTokenName
            }
        }
        return boundaryByText.map {
            SensitiveTerm(text: $0.key, requiresTokenBoundary: $0.value)
        }.sorted { $0.text < $1.text }
    }

    // MARK: - The manual-region rule mirror

    /// Mirror of the app's
    /// `PipelineCoordinator.sensitiveTermSet(applied:manualRegions:in:textLayerStatus:)`
    /// for the harness's manual regions — the seeds WITHOUT a value (a GT
    /// seed with a value stands for a detected region and keeps the
    /// matched-text rule above). On a page whose text layer is rich the
    /// words fully inside the region (the engine's word-span primitive) join
    /// the set: a multi-word run as one substring term plus each token of
    /// three or more scalars bounded; a single word as one bounded token.
    /// On any other page the region is counted, not captured. A whole-page
    /// region (area ≥ 0.95) is skipped; a below-floor or out-of-range seed
    /// never became a region and is ignored.
    static func manualRegionTerms(
        seeds: [RegionSeed], doc: PDFDocument, polygon: Bool,
        textLayerStatus: [Int: TextLayerStatus]
    ) -> (terms: [SensitiveTerm], regionsWithoutText: Int) {
        var boundaryByText: [String: Bool] = [:]
        func insert(_ text: String, bounded: Bool) {
            boundaryByText[text] = (boundaryByText[text] ?? true) && bounded
        }
        var withoutText = 0
        for seed in seeds where seed.value.isEmpty {
            guard seed.page >= 0, seed.page < doc.pageCount,
                  let region = region(from: seed, polygon: polygon) else { continue }
            let rect = region.normalizedRect
            if rect.width * rect.height >= 0.95 { continue }
            guard textLayerStatus[seed.page] == .rich, let page = doc.page(at: seed.page) else {
                withoutText += 1
                continue
            }
            let words = TextSpan.words(fullyInside: rect, polygon: region.vertices, on: page)
                .map(\.text)
            if words.count == 1 {
                insert(words[0], bounded: true)
            } else if words.count > 1 {
                insert(words.joined(separator: " "), bounded: false)
                for word in words where word.unicodeScalars.count >= 3 {
                    insert(word, bounded: true)
                }
            }
        }
        let terms = boundaryByText.map {
            SensitiveTerm(text: $0.key, requiresTokenBoundary: $0.value)
        }.sorted { $0.text < $1.text }
        return (terms, withoutText)
    }

    /// The app's dedup across contributors: one entry per text, plain
    /// substring matching when any contributor asked for it; sorted by text.
    static func mergeTerms(_ a: [SensitiveTerm], _ b: [SensitiveTerm]) -> [SensitiveTerm] {
        var boundaryByText: [String: Bool] = [:]
        for term in a + b {
            boundaryByText[term.text] = (boundaryByText[term.text] ?? true) && term.requiresTokenBoundary
        }
        return boundaryByText.map {
            SensitiveTerm(text: $0.key, requiresTokenBoundary: $0.value)
        }.sorted { $0.text < $1.text }
    }

    // MARK: - buildPDFPageData mirror

    /// Mirror of `PipelineCoordinator.buildPDFPageData` for a harness-loaded
    /// document: serial pre-extraction of cropBox + cgPage, the region floor
    /// (applied by the caller via `region(from:polygon:)`), the per-page mode
    /// selection with `TextLayerDetector.checkFallbackTriggers`, and the
    /// serial `hasText` read for searchable pages.
    static func buildPages(
        doc: PDFDocument,
        effectiveMode: PipelineMode,
        regionsByPage: [Int: [RedactionRegion]],
        textLayerStatus: [Int: TextLayerStatus],
        hasHiddenOCG: Bool
    ) -> [PDFPageData] {
        (0..<doc.pageCount).compactMap { i -> PDFPageData? in
            guard let page = doc.page(at: i) else { return nil }
            let cropBoxBounds = page.bounds(for: .cropBox)
            let cgPage = page.pageRef
            let pageRegions = regionsByPage[i] ?? []

            let pageMode: PipelineMode
            var fallbackReason: TextLayerDetector.FallbackReason?
            if effectiveMode == .searchableRedaction,
               textLayerStatus[i] == .rich {
                if let trigger = TextLayerDetector.checkFallbackTriggers(page) {
                    pageMode = .secureRasterization
                    fallbackReason = trigger
                } else {
                    pageMode = .searchableRedaction
                }
            } else {
                pageMode = .secureRasterization
                if effectiveMode == .searchableRedaction {
                    fallbackReason = .noExtractableText
                }
            }
            let hasText = pageMode == .searchableRedaction
                ? (page.string?.isEmpty == false) : false

            return PDFPageData(
                page: page, pageIndex: i, regions: pageRegions,
                fillColor: .black,
                targetDPI: 300,
                pipelineMode: pageMode,
                rotation: page.rotation,
                hasHiddenOCG: hasHiddenOCG,
                cropBoxBounds: cropBoxBounds,
                cgPage: cgPage,
                hasText: hasText,
                fallbackReason: fallbackReason)
        }
    }

    static func documentHasHiddenOCG(_ data: Data) -> Bool {
        guard let provider = CGDataProvider(data: data as CFData),
              let cgDoc = CGPDFDocument(provider) else { return false }
        return TextLayerExtractor.documentHasHiddenOCG(cgDoc)
    }

    // MARK: - processDocument mirror

    struct RedactionOutcome {
        let filterDigests: [PageFilterDigest?]
        let perPageModes: [PipelineMode]
        let perPageFallbackReasons: [TextLayerDetector.FallbackReason?]
    }

    /// Mirror of `PipelineCoordinator.processDocument` + `rasterizeWithRetry`:
    /// rotation-swapped first page size, strict 0..<count append order (pages
    /// run serially here — the app parallelizes for wall clock only; the
    /// reconstructor's order contract is what matters), the one half-DPI
    /// retry on `fillVerificationFailed`, and the written-page-count
    /// postcondition before the atomic promote.
    static func runRedaction(
        pages: [PDFPageData], outputURL: URL
    ) async throws -> RedactionOutcome {
        let rasterizer = PageRasterizer()
        let tempURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("recon_tmp_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let reconstructor = PDFStreamReconstructor(tempURL: tempURL)

        let firstSize = pages.first.map { page in
            let raw = page.cropBoxBounds
            switch page.rotation {
            case 90, 270: return CGSize(width: raw.height, height: raw.width)
            default: return raw.size
            }
        } ?? CGSize(width: 612, height: 792)
        try await reconstructor.begin(firstPageSize: firstSize)

        var digests: [PageFilterDigest?] = []
        var modes: [PipelineMode] = []
        var reasons: [TextLayerDetector.FallbackReason?] = []
        for page in pages {
            let result: RasterizeResult
            do {
                result = try await rasterizer.rasterize(page, dpiCap: 300)
            } catch let error as PipelineError { // LegalPhrases:safe (Swift keyword)
                guard case .redactionError(.fillVerificationFailed(let idx)) = error,
                      idx == page.pageIndex else { throw error }
                result = try await rasterizer.rasterize(
                    page, dpiCap: max(96, 300 / 2))
            }
            digests.append(result.filterDigest)
            modes.append(result.filterDigest != nil
                ? .searchableRedaction : .secureRasterization)
            reasons.append(result.fallbackReason)
            try await reconstructor.appendPage(result.pageOutput)
        }
        await reconstructor.finalize()
        let written = await reconstructor.writtenPageCount
        guard written == pages.count else {
            throw PipelineError.redactionError(.reconstructionFailed)
        }
        _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempURL)
        return RedactionOutcome(
            filterDigests: digests, perPageModes: modes,
            perPageFallbackReasons: reasons)
    }

    // MARK: - The scan requests (the Detection Sweep's input)

    /// The balanced preset the app scans with by default; nil when the
    /// engine bundle carries no table (the searcher then gates nothing).
    static let balancedThresholdVector: PresetThresholdVector? =
        PresetThresholdBundle.loadFromEngineBundle().presets[.balanced]

    static var balancedConfiguration: ScanRunConfiguration {
        ScanRunConfiguration(thresholdVector: balancedThresholdVector)
    }

    static var allCategoriesScan: AppliedSearchQuery {
        AppliedSearchQuery(kind: .piiScan(categories: Set(PIICategory.allCases)), options: SearchOptions())
    }

    /// The run's sweep request as the app synthesizes it at entry: every
    /// detector at the balanced preset, no user terms, nothing applied.
    static func sweepRequest() -> SearchRecheckRequest {
        SearchRecheckRequest(
            record: AppliedSearchRecord(
                query: allCategoriesScan, foundCount: 0,
                scanConfiguration: balancedConfiguration),
            appliedCount: 0, appliedPages: [], origin: .sweep)
    }

    /// An applied scan as the app records it: the source run's results at
    /// the balanced preset, every hit applied (nothing deselected).
    static func appliedScanRequest(
        results: [SearchResult], appliedCount: Int, appliedPages: Set<Int>
    ) -> SearchRecheckRequest {
        SearchRecheckRequest(
            record: AppliedSearchRecord(
                query: allCategoriesScan, foundCount: results.count,
                foundHitCap: results.count >= DocumentSearcher.maxResults,
                scanConfiguration: balancedConfiguration),
            appliedCount: appliedCount, appliedPages: appliedPages,
            origin: .applied, deselected: [])
    }

    /// The source scan the full-apply set seeds from: every detector at the
    /// balanced preset through `DocumentSearcher` (the text layer where the
    /// page carries one, the searcher's OCR path otherwise).
    static func scanSource(_ doc: PDFDocument) async -> [SearchResult] {
        let searcher = DocumentSearcher()
        await searcher.setThresholdVector(balancedThresholdVector)
        var options = SearchOptions()
        options.includeOCR = true
        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .piiScan(categories: Set(PIICategory.allCases), options: options),
            progress: { _, _ in })
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }
        return results
    }

    /// Scan hits as region seeds: one per hit, the category by name (the
    /// mirror's boundary rule keys on "name"), the value the matched text.
    static func scanSeeds(from results: [SearchResult]) -> [RegionSeed] {
        results.enumerated().map { index, hit in
            RegionSeed(
                gtId: "scan_\(index)", value: hit.matchedText,
                category: hit.piiCategory?.rawValue.lowercased() ?? "custom",
                page: hit.pageIndex, rect: hit.normalizedRect)
        }
    }

    // MARK: - runVerification (the product's orchestrator)

    /// The verification pass as the product runs it: `VerificationOrchestrator`
    /// (the page-count gate first, the phase partition by
    /// `VerificationLayer.phase`, the parallel base batch with ONE
    /// PDFDocument instance per parallel layer and the sequential-shared
    /// fallback, the sequential phases, the post-sequential batch on one
    /// output pass, the canonical assembly, `aggregateStatus`). The harness
    /// applies no typed search, so the Search Re-check reports INFO on every
    /// cell; every cell carries the run's sweep request (and the full-apply
    /// set its applied scan), so the Detection Sweep reads every output.
    static func runVerificationSweep(
        outputURL: URL,
        sourcePageCount: Int,
        regions: [Int: [RedactionRegion]],
        sensitiveTerms: [SensitiveTerm],
        effectiveMode: PipelineMode,
        filterDigests: [PageFilterDigest?],
        perPageModes: [PipelineMode],
        perPageFallbackReasons: [TextLayerDetector.FallbackReason?],
        appliedSearches: [SearchRecheckRequest] = [sweepRequest()],
        manualRegionsWithoutText: Int = 0
    ) async throws -> VerificationReport {
        guard let sharedDoc = PDFDocument(url: outputURL) else {
            throw PipelineError.verificationError(.engineCrash(layerIndex: 0))
        }
        let wrapped = SendablePDFDocument(sharedDoc)
        return try await VerificationOrchestrator().run(
            outputDocument: wrapped,
            sourcePageCount: sourcePageCount,
            regions: regions,
            sensitiveTerms: sensitiveTerms,
            pipelineMode: effectiveMode,
            filterDigests: filterDigests,
            perPageModes: perPageModes,
            perPageFallbackReasons: perPageFallbackReasons,
            appliedSearches: appliedSearches,
            manualRegionsWithoutText: manualRegionsWithoutText,
            provisionLayerDocuments: { layers in
                // One independent PDFDocument per parallel layer (the app's
                // loadParallelLayerDocuments contract); nil ⇒ the batch runs
                // sequentially on the shared instance.
                var docs: [VerificationLayer: SendablePDFDocument] = [:]
                for layer in layers {
                    guard let doc = PDFDocument(url: outputURL) else { return nil }
                    docs[layer] = SendablePDFDocument(doc)
                }
                return docs
            },
            events: { _ in })
    }
}
