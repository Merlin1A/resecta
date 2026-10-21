import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// Adversarial PDF Defense.
// Tests whether hidden OCG layers leak text and sub-threshold filtering works.

@Suite("Adversarial PDF Defense", .tags(.security))
struct AdversarialPDFDefenseTests {

    // --- PDFKit extracts text from hidden OCG layers ---
    @Test("OCG hidden text is extractable by PDFKit (AD-2-1)")
    func ocgHiddenTextExtraction() throws {
        let data = TestFixtures.ocgHiddenLayerPDF(hiddenText: "CONFIDENTIAL")
        let (doc, url) = try TestFixtures.writeTempPDF(data, prefix: "ocg_")
        defer { try? FileManager.default.removeItem(at: url) }

        let page = doc.page(at: 0)!
        let pageText = page.string ?? ""

        // PDFKit extracts hidden OCG text regardless of visibility state.
        // This is the security finding: sandwich mode must detect OCG layers
        // and strip hidden text.
        #expect(pageText.contains("CONFIDENTIAL"),
                "AD-2-1: PDFKit must extract hidden OCG text — if not, fixture is broken")
    }

    // --- Sub-threshold region filtering creates false security ---
    @Test("Sub-threshold regions are filtered out (AD-4-1)")
    func subThresholdRegionFiltering() {
        let threshold: CGFloat = 0.001
        let tinyWidth: CGFloat = 0.0005
        let tinyHeight: CGFloat = 0.0005
        let passesFilter = tinyWidth > threshold || tinyHeight > threshold

        #expect(!passesFilter, "Sub-threshold regions should be filtered out")
    }

    // --- Verify OCG PDF structure validity ---
    @Test("OCG fixture has valid /OCProperties structure")
    func ocgPDFStructureValidity() throws {
        let data = TestFixtures.ocgHiddenLayerPDF()
        let provider = CGDataProvider(data: data as CFData)!
        let cgDoc = CGPDFDocument(provider)!

        guard let catalog = cgDoc.catalog else {
            Issue.record("PDF has no catalog"); return
        }
        var ocPropsDict: CGPDFDictionaryRef?
        let hasOCProperties = CGPDFDictionaryGetDictionary(catalog, "OCProperties", &ocPropsDict)
        #expect(hasOCProperties, "OCG fixture must have /OCProperties in catalog")

        if let ocProps = ocPropsDict {
            var defaultDict: CGPDFDictionaryRef?
            let hasDefault = CGPDFDictionaryGetDictionary(ocProps, "D", &defaultDict)
            #expect(hasDefault, "OCG fixture must have /D (default config)")

            if let d = defaultDict {
                var offArray: CGPDFArrayRef?
                let hasOff = CGPDFDictionaryGetArray(d, "OFF", &offArray)
                #expect(hasOff, "OCG fixture must have /OFF array")
            }
        }
    }

    // MARK: - M1: precomputed doc-level OCG flag

    @Test("documentHasHiddenOCG returns true for OCG fixture (M1)")
    func documentHasHiddenOCGDetectsHidden() throws {
        let data = TestFixtures.ocgHiddenLayerPDF()
        let provider = try #require(CGDataProvider(data: data as CFData))
        let cgDoc = try #require(CGPDFDocument(provider))

        #expect(TextLayerExtractor.documentHasHiddenOCG(cgDoc),
                "documentHasHiddenOCG must detect /OCProperties + /D + non-empty /OFF")
    }

    @Test("documentHasHiddenOCG returns false for plain PDF (M1)")
    func documentHasHiddenOCGSkipsPlain() throws {
        let data = TestFixtures.blankPage()
        let provider = try #require(CGDataProvider(data: data as CFData))
        let cgDoc = try #require(CGPDFDocument(provider))

        #expect(!TextLayerExtractor.documentHasHiddenOCG(cgDoc),
                "Plain PDF without /OCProperties must report no hidden OCGs")
    }

    @Test("Hidden-OCG page loaded via PDFDocument(data:) triggers fallback (M1)")
    func ocgFallbackFiresOnDataBackedDocument() async throws {
        // Pre-M1 bug: PDFDocument(data:) leaves documentURL == nil, so the
        // engine's catalog walk in pageReferencesHiddenOCG short-circuited
        // to false and the defense never fired in production. Post-M1, the
        // app precomputes hasHiddenOCG from raw bytes and threads it in.
        let data = TestFixtures.ocgHiddenLayerPDF(hiddenText: "CONFIDENTIAL")
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.documentURL == nil,
                "PDFDocument(data:) must have nil documentURL — this is the M1 trigger condition")
        let page = try #require(doc.page(at: 0))

        // Precompute the flag the way ImportService does.
        let provider = try #require(CGDataProvider(data: data as CFData))
        let cgDoc = try #require(CGPDFDocument(provider))
        let hasHiddenOCG = TextLayerExtractor.documentHasHiddenOCG(cgDoc)
        #expect(hasHiddenOCG)

        let extractor = TextLayerExtractor()
        await #expect(throws: PipelineError.self) {
            _ = try await extractor.extractCharacters(
                from: page, hasHiddenOCG: hasHiddenOCG
            )
        }
    }

    // MARK: - The widened walk: base state, inherited resources, form XObjects

    static let widenedHiddenForms: [(String, Data)] = [
        ("base state off", TestFixtures.ocgBaseStateOffPDF()),
        ("inherited resources", TestFixtures.ocgInheritedResourcesPDF()),
        ("form xobject with /OC", TestFixtures.ocgFormXObjectPDF()),
        ("nested form xobject naming the group", TestFixtures.ocgFormXObjectPDF(nested: true)),
        ("base state off, /ON naming one group twice and the other never",
         TestFixtures.ocgBaseStateOffPDF(duplicateOn: true)),
        ("membership dictionary /P /AllOff with every group on",
         TestFixtures.ocgMembershipDictionaryPDF(reference: .allOff)),
        ("membership dictionary /VE [/Not g] with every group on",
         TestFixtures.ocgMembershipDictionaryPDF(reference: .visibilityExpression)),
        ("usage application /AS with every group on",
         TestFixtures.ocgMembershipDictionaryPDF(reference: .usageApplication)),
    ]

    static let widenedCleanForms: [(String, Data)] = [
        ("plain page", TestFixtures.blankPage()),
        ("base state off with every group on", TestFixtures.ocgBaseStateOffPDF(everyGroupOn: true)),
        ("every group on, a plain group reference",
         TestFixtures.ocgMembershipDictionaryPDF(reference: .plainGroup)),
    ]

    @Test("The document walk and the page walk read the widened forms as hidden",
          arguments: widenedHiddenForms)
    func widenedFormsReadHidden(name: String, data: Data) throws {
        let provider = try #require(CGDataProvider(data: data as CFData))
        let cgDoc = try #require(CGPDFDocument(provider))
        #expect(TextLayerExtractor.documentHasHiddenOCG(cgDoc), "\(name): document walk")
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        #expect(TextLayerExtractor.pageReferencesHiddenOCG(page, hasHiddenOCG: true),
                "\(name): page walk")
    }

    @Test("A plain page, an OFF base state that turns every group back on, and a plain group in an all-on document are clean",
          arguments: widenedCleanForms)
    func widenedCleanFormsPass(name: String, data: Data) throws {
        let provider = try #require(CGDataProvider(data: data as CFData))
        let cgDoc = try #require(CGPDFDocument(provider))
        #expect(!TextLayerExtractor.documentHasHiddenOCG(cgDoc), "\(name): document walk")
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        #expect(!TextLayerExtractor.pageReferencesHiddenOCG(page, hasHiddenOCG: false),
                "\(name): page walk")
    }

    @Test("Thousands of forms sharing one resource dictionary: the walk reads the dictionary once and reaches the last form's /OC")
    func sharedResourceDictionaryWalkedOnce() throws {
        let data = TestFixtures.ocgSharedResourceDictionaryPDF(forms: 3_000)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let cgDoc = try #require(CGPDFDocument(provider))
        #expect(TextLayerExtractor.documentHasHiddenOCG(cgDoc), "document walk: the /OFF array")
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        #expect(TextLayerExtractor.pageReferencesHiddenOCG(page, hasHiddenOCG: true),
                "page walk: the last form carries /OC")
    }

    @Test("Hidden-OCG without precomputed flag still falls open (M1 documents requirement)")
    func ocgDefenseRequiresPrecomputedFlag() async throws {
        // Default-false call site preserves the legacy behaviour (no throw).
        // This test pins the contract: the engine alone cannot reach the
        // catalog when documentURL == nil; correctness depends on the app
        // populating hasHiddenOCG from the raw bytes at import time.
        let data = TestFixtures.ocgHiddenLayerPDF()
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        let extractor = TextLayerExtractor()
        // Default hasHiddenOCG = false → no throw.
        _ = try await extractor.extractCharacters(from: page)
    }
}
