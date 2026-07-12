import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Pkg G.3 — TRUST-template-preview-count-mismatch +
// UX-template-preview-precount.
//
// The template picker previously displayed "Add N entries" where N
// included entries that `performImport` would silently skip
// (empty / over-cap / unsafe regex). The pre-filter path
// (`CustomTermsTemplatePicker.partitionValid`) drops those at preview
// build time so the confirmation count matches the actual import
// count.

@Suite("CustomTermsTemplatePicker — preview/import parity (Pkg G.3)", .tags(.search))
@MainActor
struct CustomTermsTemplatePickerTests {

    @Test("Preview count matches actual import count (pre-filter path)")
    func testPreviewCountMatchesActualImport() async {
        // Two valid + two invalid candidates:
        //   - empty pattern  → fails isValidUserTerm
        //   - 201-char pattern → fails length cap
        let validA = UserTerm(pattern: "^A$", isRegex: true)
        let validB = UserTerm(pattern: "^B$", isRegex: true)
        let invalidEmpty = UserTerm(pattern: "", isRegex: true)
        let invalidTooLong = UserTerm(
            pattern: String(repeating: "x", count: UserTermsStore.patternLengthCap + 1),
            isRegex: false
        )
        let candidates: [UserTerm] = [validA, invalidEmpty, validB, invalidTooLong]

        let partition = await CustomTermsTemplatePicker.partitionValid(candidates)
        #expect(partition.valid.count == 2)
        #expect(partition.invalid.count == 2)
        #expect(partition.valid.map(\.pattern) == ["^A$", "^B$"])

        // The accepted import count equals the valid-after-dedup count.
        // Mirror the dedup step the picker runs after partitioning.
        let dedup = CustomTermsTemplateLoader.deduplicating(
            partition.valid, against: []
        )
        let acceptedCount = dedup.toImport.count
        #expect(acceptedCount == partition.valid.count)
        #expect(acceptedCount != candidates.count,
                "If the raw candidate count and the accepted count match, the test fixture isn't exercising the invalid-skip path.")
    }

    @Test("Empty-pattern entries excluded from valid set")
    func testEmptyPatternRejected() async {
        let candidates: [UserTerm] = [
            UserTerm(pattern: "", isRegex: false),
            UserTerm(pattern: "Smith", isRegex: false),
        ]
        let partition = await CustomTermsTemplatePicker.partitionValid(candidates)
        #expect(partition.valid.count == 1)
        #expect(partition.valid.first?.pattern == "Smith")
        #expect(partition.invalid.count == 1)
    }

    @Test("Over-length entries excluded from valid set")
    func testOverLengthRejected() async {
        let overCap = String(repeating: "x", count: UserTermsStore.patternLengthCap + 1)
        let candidates: [UserTerm] = [
            UserTerm(pattern: overCap, isRegex: false),
            UserTerm(pattern: "Smith", isRegex: false),
        ]
        let partition = await CustomTermsTemplatePicker.partitionValid(candidates)
        #expect(partition.valid.count == 1)
        #expect(partition.invalid.count == 1)
    }

    @Test("Catastrophic regex entries excluded from valid set")
    func testCatastrophicRegexRejected() async {
        // `(a+)+` is rejected by `validateRegexPattern` (nested
        // quantifier heuristic), which `isValidUserTerm` consults
        // when `isRegex == true`.
        let candidates: [UserTerm] = [
            UserTerm(pattern: "(a+)+", isRegex: true),
            UserTerm(pattern: #"^\d{3}$"#, isRegex: true),
        ]
        let partition = await CustomTermsTemplatePicker.partitionValid(candidates)
        #expect(partition.valid.count == 1)
        #expect(partition.invalid.count == 1)
        #expect(partition.valid.first?.pattern == #"^\d{3}$"#)
    }

    @Test("All-valid candidates partition as (all, none)")
    func testAllValid() async {
        let candidates: [UserTerm] = [
            UserTerm(pattern: "^A$", isRegex: true),
            UserTerm(pattern: "Smith", isRegex: false),
        ]
        let partition = await CustomTermsTemplatePicker.partitionValid(candidates)
        #expect(partition.valid.count == 2)
        #expect(partition.invalid.isEmpty)
    }

    @Test("Empty candidate list partitions as (none, none)")
    func testEmptyCandidates() async {
        let partition = await CustomTermsTemplatePicker.partitionValid([])
        #expect(partition.valid.isEmpty)
        #expect(partition.invalid.isEmpty)
    }

    // MARK: - CL-QP1-02 — template-picker entry hidden for V1.0

    @Test("Template-picker entry point is gated off (CL-QP1-02)")
    func testTemplatePickerEntryHidden() {
        // The browse button in CustomTermsView.templatesSection is behind
        // this flag for V1.0 (approved cut, QCP-P 2026-07-03). The picker
        // view and import machinery stay compiled — this suite exercising
        // `partitionValid` above is part of that preserved surface.
        #expect(CustomTermsView.templatePickerEnabled == false)
    }

    // MARK: - QW-2 (D07-F2) async ReDoS sentinel at preview time

    @Test("Heuristic-passing, sentinel-failing regex excluded from valid set")
    func testSentinelFailingRegexRejected() async {
        // Sequential unbounded stars with an end anchor: no groups, so
        // the RegexSafetyPrecheck and the nested-quantifier heuristic
        // both pass — but against the sentinel payload's 2048-char `a`
        // run the backtracking blows the 200 ms probe budget, so
        // `RegexSentinelCheck.validate` rejects it. Before QW-2 this
        // pattern imported cleanly and stalled the next scan instead.
        let adversarial = UserTerm(pattern: "a*a*a*a*a*a*a*a*a*a*$", isRegex: true)
        // Guard the fixture premise: the static heuristic must accept it,
        // otherwise this test is no longer exercising the sentinel layer.
        #expect(UserTermsStore.isValidUserTerm(adversarial),
                "fixture stale: static heuristic now rejects the adversarial pattern")
        let safe = UserTerm(pattern: #"^\d{3}$"#, isRegex: true)
        let literal = UserTerm(pattern: "Smith", isRegex: false)

        let partition = await CustomTermsTemplatePicker.partitionValid(
            [adversarial, safe, literal]
        )
        #expect(partition.valid.map(\.pattern) == [#"^\d{3}$"#, "Smith"])
        #expect(partition.invalid.map(\.pattern) == ["a*a*a*a*a*a*a*a*a*a*$"])

        // Preview==commit contract: the count shown ("Add N entries") is
        // derived from the same valid-after-dedup set `performImport`
        // consumes, so excluding the pattern here keeps them in lockstep.
        let dedup = CustomTermsTemplateLoader.deduplicating(
            partition.valid, against: []
        )
        #expect(dedup.toImport.count == partition.valid.count)
    }
}
