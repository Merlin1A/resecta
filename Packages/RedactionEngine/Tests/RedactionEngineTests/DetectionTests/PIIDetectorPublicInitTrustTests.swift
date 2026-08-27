import Testing
import Foundation
@testable import RedactionEngine

// The public `PIIDetector.init` default arguments consult the shared
// memoized signature verdict (`GazetteerTrust`), so `PIIDetector()` cannot
// load a corpus the manifest-signature check would have withheld. The
// stored properties are private; `Mirror` reads their nil-ness.
@Suite("PIIDetector public init honours the signature verdict")
struct PIIDetectorPublicInitTrustTests {

    private static let gazetteerLabels = [
        "nameGazetteer", "dlPatternGazetteer", "passportPatternGazetteer",
        "contextLoader", "negativeContextGazetteer",
    ]

    private static func storedProperties(of detector: PIIDetector) -> [String: Any] {
        var result: [String: Any] = [:]
        for child in Mirror(reflecting: detector).children {
            if let label = child.label { result[label] = child.value }
        }
        return result
    }

    private static func isNilOptional(_ value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional && mirror.children.isEmpty
    }

    @Test("Forced-false verdict: PIIDetector() carries nil for all five gazetteer properties")
    func forcedFalseVerdictYieldsNilGazetteers() {
        GazetteerTrust.$verdictOverrideForTesting.withValue(false) {
            let detector = PIIDetector()
            let properties = Self.storedProperties(of: detector)
            for label in Self.gazetteerLabels {
                guard let value = properties[label] else {
                    Issue.record("expected a stored property named \(label)")
                    continue
                }
                #expect(Self.isNilOptional(value),
                        "\(label) must be nil when the signature verdict is false")
            }
        }
    }

    @Test("Shipped valid signature: PIIDetector() loads all five gazetteers")
    func shippedBundleYieldsLiveGazetteers() {
        let detector = PIIDetector()
        let properties = Self.storedProperties(of: detector)
        for label in Self.gazetteerLabels {
            guard let value = properties[label] else {
                Issue.record("expected a stored property named \(label)")
                continue
            }
            #expect(!Self.isNilOptional(value),
                    "\(label) must be non-nil with the shipped valid signature")
        }
    }
}
