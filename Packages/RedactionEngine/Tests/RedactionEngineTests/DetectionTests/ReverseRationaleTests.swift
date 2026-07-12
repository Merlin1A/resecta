import Testing
import Foundation
@testable import RedactionEngine

// W9 — PIIDetector.reverseRationale(...) tests. Each fixture covers one
// resolution path: doctype-gated, user-never-flag, user-always-flag,
// no-match, above/below threshold.

@Suite("PIIDetector.reverseRationale")
struct ReverseRationaleTests {

    private var balancedVector: PresetThresholdVector {
        PresetThresholdBundle.builtInDefaults.presets[.balanced]!
    }

    @Test("above-threshold SSN in positive context")
    func ssnAboveThreshold() async {
        let detector = PIIDetector()
        let snippet = "123-45-6789"
        let context = "Patient SSN: 123-45-6789 on admission."
        let result = await detector.reverseRationale(
            for: snippet,
            fullContext: context,
            doctype: nil,
            thresholdVector: balancedVector
        )
        let ssn = result.considered.first { $0.category == .ssn }
        #expect(ssn != nil)
        if let ssn {
            #expect(ssn.reason == .aboveThreshold)
            #expect(ssn.matched == true)
            #expect(ssn.finalScore ?? 0.0 >= (ssn.threshold ?? 0.0))
        }
    }

    @Test("no-match produces .noMatch for unrelated categories")
    func unrelatedTextProducesNoMatch() async {
        let detector = PIIDetector()
        let snippet = "some-nonpii-text"
        let context = "Contains some-nonpii-text in the middle."
        let result = await detector.reverseRationale(
            for: snippet,
            fullContext: context,
            doctype: nil,
            thresholdVector: balancedVector
        )
        let ssn = result.considered.first { $0.category == .ssn }
        #expect(ssn?.reason == .noMatch)
        let cc = result.considered.first { $0.category == .creditCard }
        #expect(cc?.reason == .noMatch)
    }

    @Test("doctype-gated categories return .doctypeGated")
    func doctypeGateSuppressesCategories() async {
        let detector = PIIDetector()
        let snippet = "1234567890"
        let context = "Provider NPI: 1234567890 billing note."
        let result = await detector.reverseRationale(
            for: snippet,
            fullContext: context,
            // NPI only runs on medical/foia/nil. Setting financial gates it out.
            doctype: .financial,
            thresholdVector: balancedVector
        )
        let npi = result.considered.first { $0.category == .npi }
        #expect(npi?.reason == .doctypeGated)
        #expect(npi?.matched == false)
        #expect(result.doctypeGatedOut.contains(.npi))
    }

    @Test("user never-flag suppression reports .suppressedByUserTerm")
    func userNeverFlagSuppresses() async {
        let detector = PIIDetector()
        let matcher = UserTermMatcher.compile(
            alwaysFlag: [],
            neverFlag: [UserTerm(pattern: "123-45-6789", isRegex: false)]
        )
        let snippet = "123-45-6789"
        let context = "SSN 123-45-6789 appears."
        let result = await detector.reverseRationale(
            for: snippet,
            fullContext: context,
            doctype: nil,
            thresholdVector: balancedVector,
            userTerms: matcher
        )
        for consideration in result.considered where consideration.reason != .doctypeGated {
            #expect(
                consideration.reason == .suppressedByUserTerm,
                "user never-flag must suppress all non-gated categories"
            )
        }
    }

    @Test("user always-flag promotion reports .matchedAlwaysFlag")
    func userAlwaysFlagPromotes() async {
        let detector = PIIDetector()
        let matcher = UserTermMatcher.compile(
            alwaysFlag: [UserTerm(pattern: "ACME-001", isRegex: false)],
            neverFlag: []
        )
        let snippet = "ACME-001"
        let context = "Project code ACME-001 on the cover."
        let result = await detector.reverseRationale(
            for: snippet,
            fullContext: context,
            doctype: nil,
            thresholdVector: balancedVector,
            userTerms: matcher
        )
        let ssnRow = result.considered.first { $0.category == .ssn }
        #expect(ssnRow?.reason == .matchedAlwaysFlag)
        #expect(ssnRow?.matched == true)
    }

    @Test("snippet not in context yields .snippetNotInContext rows")
    func missingSnippetProducesSnippetNotInContext() async {
        let detector = PIIDetector()
        let snippet = "unique-token-xyz"
        let context = "This buffer does not contain the snippet."
        let result = await detector.reverseRationale(
            for: snippet,
            fullContext: context,
            doctype: nil,
            thresholdVector: balancedVector
        )
        for row in result.considered {
            #expect(row.reason == .snippetNotInContext)
        }
        #expect(result.contextRange.location == NSNotFound)
    }

    @Test("considered list covers every PIICategory")
    func everyCategoryAppears() async {
        let detector = PIIDetector()
        let result = await detector.reverseRationale(
            for: "abc",
            fullContext: "xxx abc yyy",
            doctype: nil,
            thresholdVector: balancedVector
        )
        let categoriesSeen = Set(result.considered.map(\.category))
        #expect(categoriesSeen == Set(PIICategory.allCases))
    }
}
