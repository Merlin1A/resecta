import Testing
import Foundation
@testable import RedactionEngine

// CAT-065 — DocumentTypeClassifier load diagnostics. A missing or corrupt
// doctype-keywords.json previously degraded silently (the classifier returns
// `.generic` for every page) with nothing surfaced to the user.
// `loadWithDiagnostics` now folds the outcome into a `GazetteerLoadDiagnostics`
// so the auto-detect-degraded banner can fire, mirroring the SEC-7
// gazetteer-loader diagnostics.

@Suite("Doctype classifier load diagnostics (CAT-065)")
struct DoctypeLoadDiagnosticsTests {

    private static var classifierKey: String {
        GazetteerLoadDiagnostics.Gazetteer.documentTypeClassifier.rawValue
    }

    @Test("Missing doctype-keywords.json surfaces a load diagnostic")
    func testMissingDoctypeKeywordsDegrades() {
        // An empty bundle has no Classifier/doctype-keywords.json, so the factory
        // reports a documentTypeClassifier load failure instead of the classifier
        // silently returning .generic.
        let (_, diagnostic) = DocumentTypeClassifier.loadWithDiagnostics(bundle: Bundle())

        #expect(diagnostic?.didDegrade == true)
        #expect(diagnostic?.failedGazetteers.contains(Self.classifierKey) == true)
        // The reason is mechanism-only and non-empty.
        #expect(diagnostic?.failureReasons[Self.classifierKey]?.isEmpty == false)
    }

    @Test("Bundled doctype-keywords.json loads without a diagnostic")
    func testBundledDoctypeKeywordsLoadsClean() {
        // The engine ships Classifier/doctype-keywords.json in its module bundle,
        // so the production load path reports no degradation. Use the default-arg
        // form so `.module` resolves to the ENGINE bundle (passing `.module` from
        // the test target would resolve to the test bundle, which has no engine
        // resources — exactly the production-faithful default PIIDetector uses).
        let (classifier, diagnostic) = DocumentTypeClassifier.loadWithDiagnostics()
        #expect(diagnostic == nil)
        _ = classifier  // constructed successfully
    }

    @Test("Gazetteer signature-fail path does not auto-report the classifier")
    func testSignatureFailPathExcludesClassifier() {
        // Blast-radius guard: an empty bundle fails the gazetteer-manifest
        // signature, and that path must NOT auto-report the classifier — its
        // JSON is not covered by the manifest signature. The eight gazetteer
        // loaders still surface (preserving the count==8 invariant pinned by
        // PIIDetectorInitDegradedTests).
        let (_, diagnostics) = PIIDetector.loadWithDiagnostics(bundle: Bundle())
        #expect(diagnostics.didDegrade)
        #expect(diagnostics.failedGazetteers.contains(Self.classifierKey) == false)
    }
}
