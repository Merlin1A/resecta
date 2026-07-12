import Testing
import PDFKit
@testable import RedactionEngine

@Suite("OCRCacheCoherence", .tags(.search))
struct OCRCacheCoherenceTests {

    @Test("Text-path LRU eviction removes ocrNormalizedConcat entry in lockstep (N-12)")
    func textPathEvictionMaintainsNormalizedConcatParity() async {
        let data = TestFixtures.imageOnlyPDF()
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to build image-only fixture PDF")
            return
        }

        let searcher = DocumentSearcher()

        let occupiedCount = 50
        let missingIndex = 0
        let expectedEvictedKey = 1
        await searcher._testSeedOCRCacheForCoherence(
            skippingPageIndex: missingIndex,
            occupiedCount: occupiedCount
        )

        let preCacheKeys = await searcher._testOCRCacheKeys
        let preNormKeys = await searcher._testOCRNormalizedConcatKeys
        #expect(preCacheKeys == preNormKeys, "seeded caches should start in lockstep")
        #expect(preCacheKeys.count == occupiedCount)
        #expect(preNormKeys.contains(expectedEvictedKey))

        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .text("zzz_no_match_zzz", options: SearchOptions(includeOCR: true)),
            progress: { _, _ in }
        )
        for await _ in stream { /* drain */ }

        let postCacheKeys = await searcher._testOCRCacheKeys
        let postNormKeys = await searcher._testOCRNormalizedConcatKeys

        #expect(!postNormKeys.contains(expectedEvictedKey),
                "Text-path LRU eviction must remove ocrNormalizedConcat[\(expectedEvictedKey)] (N-12 parity)")
        #expect(postNormKeys.isSubset(of: postCacheKeys),
                "Every ocrNormalizedConcat key must correspond to an ocrCache key")
        #expect(postCacheKeys.contains(missingIndex),
                "Page \(missingIndex) should be cached after the text-path miss")
    }

    @Test("Text-path eviction does not leave a stale concat that survives a later PII scan")
    func textPathEvictionThenPIIScanRebuildsNormalizedConcat() async {
        let data = TestFixtures.imageOnlyPDF()
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to build image-only fixture PDF")
            return
        }

        let searcher = DocumentSearcher()
        await searcher._testSeedOCRCacheForCoherence(
            skippingPageIndex: 0,
            occupiedCount: 50
        )

        let textStream = searcher.search(
            SendablePDFDocument(doc),
            mode: .text("zzz_no_match_zzz", options: SearchOptions(includeOCR: true)),
            progress: { _, _ in }
        )
        for await _ in textStream { /* drain */ }

        let preEvictedKey = 1
        let postCacheKeys = await searcher._testOCRCacheKeys
        let postNormKeys = await searcher._testOCRNormalizedConcatKeys
        #expect(!postCacheKeys.contains(preEvictedKey),
                "Page \(preEvictedKey) should be evicted from ocrCache")
        #expect(!postNormKeys.contains(preEvictedKey),
                "Page \(preEvictedKey) must also be evicted from ocrNormalizedConcat — stale normalized data would cause PII rect drift")
    }
}
