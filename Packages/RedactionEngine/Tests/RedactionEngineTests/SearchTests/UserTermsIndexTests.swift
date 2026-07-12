import Testing
import PDFKit
import Foundation
@testable import RedactionEngine

// W-P — UserTermsIndex × shipped-asset merge layer per §D16 = P1
// (user always wins).
//
// V1 ships flat-N1 keying: every entry lands at
// (category: nil, doctype: nil, surfaceForm: term.pattern.normalized)
// because the V1 UserTerm model is (pattern, isRegex) only. Per-(category,
// doctype) keying is V1.1+. STRAT §5.3 stop-conditions; impl-plan v5.1 §W-P.

@Suite("UserTermsIndex (W-P custom-terms merge)", .tags(.search))
struct UserTermsIndexTests {

    // MARK: - Decision API (V1 flat-N1)

    @Test("Empty index reports isEmpty + decision .none")
    func emptyIndexNone() {
        let index = UserTermsIndex.compile(alwaysFlag: [], neverFlag: [])
        #expect(index.isEmpty)
        if case .none = index.decision(for: "anything") { } else {
            Issue.record("empty index must return .none")
        }
    }

    @Test("Never-flag literal entry resolves to .neverFlag with original pattern")
    func neverFlagLiteralDecision() {
        let index = UserTermsIndex.compile(
            alwaysFlag: [],
            neverFlag: [UserTerm(pattern: "Acme Corp", isRegex: false)]
        )
        if case .neverFlag(let pattern) = index.decision(for: "ACME CORP") {
            #expect(pattern == "Acme Corp",
                    "decision should echo the user-authored pattern, not the matched text")
        } else {
            Issue.record("expected .neverFlag for case-insensitive literal match")
        }
    }

    @Test("Always-flag literal entry resolves to .alwaysFlag")
    func alwaysFlagLiteralDecision() {
        let index = UserTermsIndex.compile(
            alwaysFlag: [UserTerm(pattern: "PROJ-1234", isRegex: false)],
            neverFlag: []
        )
        if case .alwaysFlag(let pattern) = index.decision(for: "proj-1234") {
            #expect(pattern == "PROJ-1234")
        } else {
            Issue.record("expected .alwaysFlag")
        }
    }

    @Test("Never-flag wins over always-flag when both would fire (defensive)")
    func neverFlagBeatsAlwaysFlag() {
        // Same surface form on both lists — UI prevents this at insertion,
        // but the engine stays robust against persisted blobs that drifted.
        let index = UserTermsIndex.compile(
            alwaysFlag: [UserTerm(pattern: "BadgeID", isRegex: false)],
            neverFlag: [UserTerm(pattern: "BadgeID", isRegex: false)]
        )
        if case .neverFlag = index.decision(for: "BadgeID") { } else {
            Issue.record("never-flag must beat always-flag on the same surface form")
        }
    }

    // MARK: - merge(into:doctype:)

    @Test("merge filters out PIIMatches whose text fires never-flag")
    func mergeSuppressesNeverFlag() {
        let index = UserTermsIndex.compile(
            alwaysFlag: [],
            neverFlag: [UserTerm(pattern: "999-99-9999", isRegex: false)]
        )
        let suppressed = PIIDetector.PIIMatch(
            text: "999-99-9999",
            range: NSRange(location: 0, length: 11),
            kind: .ssn,
            confidence: 0.95
        )
        let kept = PIIDetector.PIIMatch(
            text: "111-22-3333",
            range: NSRange(location: 12, length: 11),
            kind: .ssn,
            confidence: 0.95
        )
        let merged = index.merge(into: [suppressed, kept], doctype: nil)
        #expect(merged.count == 1)
        #expect(merged.first?.text == "111-22-3333")
    }

    @Test("V1 flat-N1: doctype parameter is informational — entry shadows across every doctype")
    func emptyDoctypesShadowAllDoctypes() {
        // V1 every entry keys on (category: nil, doctype: nil). Calling
        // merge with any concrete doctype must still suppress, because
        // the index is doctype-agnostic in V1 by design.
        let index = UserTermsIndex.compile(
            alwaysFlag: [],
            neverFlag: [UserTerm(pattern: "999-99-9999", isRegex: false)]
        )
        let match = PIIDetector.PIIMatch(
            text: "999-99-9999",
            range: NSRange(location: 0, length: 11),
            kind: .ssn,
            confidence: 0.9
        )
        for doctype in DoctypeClass.allCases {
            let merged = index.merge(into: [match], doctype: doctype)
            #expect(merged.isEmpty,
                    "doctype \(doctype) must not bypass the V1 flat-N1 never-flag")
        }
        let mergedNil = index.merge(into: [match], doctype: nil)
        #expect(mergedNil.isEmpty, "nil doctype must also suppress")
    }

    // MARK: - Per-blob isolation

    @Test("Indices compiled from disjoint user-terms blobs do not share state")
    func perProfileIsolation() {
        // Each compiled UserTermsIndex is independent: blob A's
        // never-flag entry must not bleed into the decisions of an
        // index compiled from blob B.
        let profileA = UserTermsIndex.compile(
            alwaysFlag: [],
            neverFlag: [UserTerm(pattern: "shared-A", isRegex: false)]
        )
        let profileB = UserTermsIndex.compile(
            alwaysFlag: [UserTerm(pattern: "shared-B", isRegex: false)],
            neverFlag: []
        )

        if case .neverFlag = profileA.decision(for: "shared-A") { } else {
            Issue.record("Profile A should see its own never-flag entry")
        }
        if case .none = profileB.decision(for: "shared-A") { } else {
            Issue.record("Profile B must not see Profile A's never-flag entry")
        }
        if case .alwaysFlag = profileB.decision(for: "shared-B") { } else {
            Issue.record("Profile B should see its own always-flag entry")
        }
        if case .none = profileA.decision(for: "shared-B") { } else {
            Issue.record("Profile A must not see Profile B's always-flag entry")
        }
    }

    // MARK: - Integration through DocumentSearcher

    private func runPIIScan(
        text: String,
        categories: Set<PIICategory>,
        index: UserTermsIndex?
    ) async -> [SearchResult] {
        let data = TestFixtures.textLayerPDF(text: text)
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return []
        }
        let searcher = DocumentSearcher()
        await searcher.setUserTerms(index)
        let mode = SearchMode.piiScan(categories: categories, options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode, progress: { _, _ in }
        )
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }
        return results
    }

    @Test("Never-flag entry suppresses a shipped-detector SSN match in searchPII")
    func neverFlagSuppressesShippedDetectorMatch() async {
        // Baseline confirms the shipped SSN detector surfaces the hit
        // without any user-term gating.
        let baseline = await runPIIScan(
            text: "Patient SSN 123-45-6789 on file",
            categories: [.ssn],
            index: nil
        )
        #expect(baseline.contains(where: { $0.piiCategory == .ssn }),
                "baseline must surface SSN before we test suppression")

        let index = UserTermsIndex.compile(
            alwaysFlag: [],
            neverFlag: [UserTerm(pattern: "123-45-6789", isRegex: false)]
        )
        let suppressed = await runPIIScan(
            text: "Patient SSN 123-45-6789 on file",
            categories: [.ssn],
            index: index
        )
        #expect(!suppressed.contains(where: { $0.piiCategory == .ssn }),
                "user never-flag must suppress the shipped SSN detector hit")
    }

    @Test("Always-flag promotes a non-detected token to a synthetic Custom hit")
    func alwaysFlagPromotesNonDetected() async {
        // "Project Sentinel" is not PII per any shipped detector; with an
        // always-flag entry the engine emits a synthetic Custom hit with
        // finalScore 1.0 and ruleID "user.alwaysFlag".
        let index = UserTermsIndex.compile(
            alwaysFlag: [UserTerm(pattern: "Project Sentinel", isRegex: false)],
            neverFlag: []
        )
        let results = await runPIIScan(
            text: "Internal note: Project Sentinel kickoff scheduled",
            categories: [.ssn],
            index: index
        )
        let synthetic = results.first {
            $0.term == "Custom"
            && $0.matchedText.lowercased() == "project sentinel"
        }
        #expect(synthetic != nil,
                "always-flag must promote a non-detected surface form to a Custom hit")
        #expect(synthetic?.rationale?.ruleID == "user.alwaysFlag")
        #expect(synthetic?.rationale?.finalScore == 1.0)
    }

    // MARK: - W-P timing-equivalence regression (v5)

    @Test("W-P regression: never-flag for a structurally-valid SSN keeps SSN out of output")
    func timingEquivalenceRegression() async {
        // Locks the W-P pre-threshold suppression contract: a structurally
        // valid SSN that fires the shipped detector AND matches a user
        // never-flag must NOT appear in `searchPII()` output, regardless of
        // whether the engine runs the suppression pre- or post-threshold.
        // Snapshot result count + ruleID emissions so any regression in the
        // merge primitive (or removal of both pre- and post-threshold paths)
        // surfaces here.
        let index = UserTermsIndex.compile(
            alwaysFlag: [],
            neverFlag: [UserTerm(pattern: "123-45-6789", isRegex: false)]
        )
        let results = await runPIIScan(
            text: "Patient SSN 123-45-6789 on file",
            categories: [.ssn],
            index: index
        )

        // Snapshot: zero SSN-tagged results.
        let ssnResults = results.filter { $0.piiCategory == .ssn }
        #expect(ssnResults.isEmpty,
                "never-flag must keep the SSN out of search output entirely")

        // Snapshot: no rationale ruleID flowing through the threshold pass
        // for the suppressed text. Pre-W-P (post-threshold) timing would
        // briefly admit the hit through the threshold-pass set; W-P drops
        // it before that. Either way the user-facing output is empty —
        // this assertion locks the user-visible promise.
        let ssnRuleIDs = results
            .compactMap { $0.rationale?.ruleID }
            .filter { $0.lowercased().contains("ssn") }
        #expect(ssnRuleIDs.isEmpty,
                "no SSN-tagged ruleID may emit when never-flag covers the surface form")
    }
}
