import Testing
import Foundation
@testable import RedactionEngine

// Plan Phase 3 / §4 — Account: context-only digit strings.

@Suite("Account detector (context-only)")
struct AccountDetectorTests {

    private let detector = AccountDetector()

    private func matches(in text: String) -> [PIIDetector.PIIMatch] {
        let ns = text as NSString
        return detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
    }

    @Test("Bare digit run without context yields no match")
    func noContextRejects() {
        let results = matches(in: "Reference 123456789 on file")
        #expect(results.isEmpty)
    }

    @Test("'Account' keyword within window surfaces the number")
    func withAccountLabelSurfaces() {
        let results = matches(in: "Account: 123456789 transferred today")
        #expect(results.contains(where: { $0.text == "123456789" }))
    }

    @Test("Short 'acct.' abbreviation also triggers")
    func acctAbbreviation() {
        let results = matches(in: "Please send to acct. 998877665544")
        #expect(results.contains(where: { $0.text == "998877665544" }))
    }

    @Test("Digit run outside context window is ignored")
    func outsideWindowIgnored() {
        // Account keyword far from number (>5 tokens away).
        let text = "Account information. The quick brown fox jumps over the lazy dog 123456789 meanders."
        let results = matches(in: text)
        #expect(!results.contains(where: { $0.text == "123456789" }))
    }

    @Test("Positive context emits .contextPositive signal in rationale")
    func signalEmitsContextPositive() {
        let results = matches(in: "Account: 123456789 transferred today")
        let hit = results.first(where: { $0.text == "123456789" })
        #expect(hit?.rationale != nil)
        let isContextPositive = hit?.rationale?.signals.contains {
            if case .contextPositive = $0 { return true }
            return false
        } ?? false
        #expect(isContextPositive, "Account hit with 'Account' keyword must carry .contextPositive")
    }

    @Test("Rationale carries regexPattern signal for the account rule")
    func signalCarriesRegexFingerprint() {
        let results = matches(in: "Account: 123456789 transferred today")
        let hit = results.first(where: { $0.text == "123456789" })
        let hasRegex = hit?.rationale?.signals.contains {
            if case .regexPattern(let name) = $0 { return name == "account.regex" }
            return false
        } ?? false
        #expect(hasRegex)
    }

    // L-05: detector guard relaxed from > 0.05 to > 0.0 so intermediate
    // dampened values reach PresetThresholdVector (the real per-preset gate)
    // instead of being filtered at the detector. Zero-signal matches are
    // still rejected.

    @Test("Positive-context match has confidence > 0 and survives the guard")
    func accountWithFractionalConfidenceAccepted() {
        let results = matches(in: "Account: 123456789 transferred today")
        let hit = results.first(where: { $0.text == "123456789" })
        #expect(hit != nil, "positive-context account should survive the > 0.0 guard")
        if let confidence = hit?.confidence {
            #expect(confidence > 0.0,
                    "surviving account match must have non-zero confidence")
        }
    }

    // MARK: - CND-10 (launch-fix-v2 S5) doctype-gate broadening
    //
    // `PIIDetector.runsAccount(doctype:)` is `private static`, so these
    // exercise the gate through its only observable effect: the public
    // `detect(in:categories:doctype:)` overload, which runs the account
    // detector only when the gate is open and applies no preset-threshold
    // filter (so the raw 0.58 boosted match still surfaces here). The
    // posterior/W4 survival of that 0.58 at the balanced preset is the
    // on-device measurement gate, not a CI assertion.

    private func accountRuns(doctype: DoctypeClass?) async -> Bool {
        let detector = PIIDetector()
        let hits = await detector.detect(
            in: "Account: 123456789 transferred today",
            categories: [.account],
            doctype: doctype)
        return hits.contains { $0.text == "123456789" }
    }

    @Test("Account gate truth-table: runs on financial/medical/court/generic/nil; held on foia")
    func accountDoctypeGateTruthTable() async {
        #expect(await accountRuns(doctype: .financial), "financial runs account (unchanged)")
        #expect(await accountRuns(doctype: .medical), "medical runs account (unchanged)")
        #expect(await accountRuns(doctype: .court), "CND-10: court now runs account")
        #expect(await accountRuns(doctype: .generic), "CND-10: generic now runs account")
        #expect(await accountRuns(doctype: nil), "nil doctype runs account unconditionally")
        #expect(!(await accountRuns(doctype: .foia)), "foia holds the account gate closed")
    }

    @Test("Broadened court/generic gate still respects the account context window")
    func broadenedGateStillRequiresContext() async {
        let detector = PIIDetector()
        for doctype in [DoctypeClass.court, .generic] {
            let labeled = await detector.detect(
                in: "Account: 123456789 on file", categories: [.account], doctype: doctype)
            #expect(labeled.contains { $0.text == "123456789" },
                    "a labeled account number must surface on \(doctype)")

            let bare = await detector.detect(
                in: "Reference 123456789 on file", categories: [.account], doctype: doctype)
            #expect(!bare.contains { $0.text == "123456789" },
                    "a bare digit run without a nearby label must stay unflagged on \(doctype)")
        }
    }
}
