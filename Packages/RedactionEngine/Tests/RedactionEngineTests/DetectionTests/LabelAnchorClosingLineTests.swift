import Testing
import Foundation
@testable import RedactionEngine

// Route 2 of the label anchors: the closing line. A letter's sign-off
// (`Sincerely,` on its own line) is followed — after at most three blank
// lines left for a handwritten signature — by the signer's name on a line of
// its own. The route reads that line when it is a two-to-three-token
// capitalised run and nothing but a comma-led suffix or a period follows.
//
// Deterministic: drives `scanLabelAnchors` on its own, apart from the tagger
// rows that win the overlap inside `detectNames`.
//
// Synthetic Hartwell/Sablebrook cast only (repo test-data policy).
//
// Privacy rule (audit-lint M-1): comments and test names use
// locate/surface/resolve vocabulary.

@Suite("Label anchor routes: the closing line")
struct LabelAnchorClosingLineTests {

    private static func closings(in text: String) -> [PIIDetector.PIIMatch] {
        PIIDetector().scanLabelAnchors(in: text).filter { match in
            match.rationale?.signals.contains(.regexPattern(name: "name.label-anchor.closing-line")) == true
        }
    }

    @Test("The line after a sign-off surfaces the signer")
    func lineAfterTheSignOffSurfacesTheSigner() {
        let text = "Please call with any questions.\n\nSincerely,\nDelia Hartwell\nSablebrook Holdings"
        let hits = Self.closings(in: text)
        #expect(hits.map(\.text) == ["Delia Hartwell"])
        #expect(hits.first.map { $0.range == (text as NSString).range(of: "Delia Hartwell") } == true)
        #expect(hits.first?.confidence == PIIDetector.labelAnchorConfidence)
        #expect(hits.first?.rationale?.ruleID == PIIDetector.labelAnchorRuleID)
    }

    @Test("Blank lines for a handwritten signature are skipped, up to three")
    func blankLinesAreSkippedUpToThree() {
        #expect(Self.closings(in: "Sincerely,\n\n\n\nDelia Hartwell").map(\.text) == ["Delia Hartwell"])
        #expect(Self.closings(in: "Sincerely,\n   \n\t\nDelia Hartwell").map(\.text) == ["Delia Hartwell"])
        #expect(Self.closings(in: "Sincerely,\n\n\n\n\nDelia Hartwell").isEmpty)
    }

    @Test("Every closing phrase reads case-folded, and only with its comma on its own line")
    func everyClosingPhraseReadsCaseFolded() {
        for phrase in ["Sincerely", "Regards", "Best regards", "Kind regards", "Warm regards", "Respectfully",
                       "Respectfully submitted", "Yours truly", "Very truly yours", "Cordially", "Best", "Thank you", "Thanks"] {
            #expect(Self.closings(in: "\(phrase),\nMarcus Bellamy").map(\.text) == ["Marcus Bellamy"], "phrase \(phrase)")
            #expect(Self.closings(in: "\(phrase.uppercased()),\nMarcus Bellamy").map(\.text) == ["Marcus Bellamy"], "phrase \(phrase.uppercased())")
        }
        #expect(Self.closings(in: "Sincerely\nMarcus Bellamy").isEmpty)
        #expect(Self.closings(in: "Sincerely, Marcus Bellamy").isEmpty)
        #expect(Self.closings(in: "Sincerely yours and with thanks,\nMarcus Bellamy").isEmpty)
    }

    @Test("A comma-led suffix or a period after the name is not read; anything else means the line is not a signature")
    func suffixOrPeriodAfterTheNameIsNotRead() {
        #expect(Self.closings(in: "Best regards,\nDelia Hartwell, Esq.").map(\.text) == ["Delia Hartwell"])
        #expect(Self.closings(in: "Best regards,\nDelia Hartwell.").map(\.text) == ["Delia Hartwell"])
        #expect(Self.closings(in: "Best regards,\nDelia Hartwell Director of Sales").isEmpty)
        #expect(Self.closings(in: "Best regards,\nDelia Hartwell (Sales)").isEmpty)
        #expect(Self.closings(in: "Best regards,\nDelia Hartwell 555-0100").isEmpty)
    }

    @Test("An organisation, a placeholder, a single token or an honorific-led line is not read")
    func organisationPlaceholderSingleTokenOrHonorificIsNotRead() {
        #expect(Self.closings(in: "Regards,\nSablebrook Holdings Inc.").isEmpty)
        #expect(Self.closings(in: "Regards,\nCustomer Service Department").isEmpty)
        #expect(Self.closings(in: "Sincerely,\n[REDACTED]").isEmpty)
        #expect(Self.closings(in: "Sincerely,\nDelia").isEmpty)
        // The honorific-led shape belongs to the prefix pass.
        #expect(Self.closings(in: "Sincerely,\nDr. Delia Hartwell").isEmpty)
        // A second closing phrase is not a signature.
        #expect(Self.closings(in: "Sincerely,\nBest regards,\nDelia Hartwell").map(\.text) == ["Delia Hartwell"])
    }

    @Test("Only the first non-blank line after the sign-off is read")
    func onlyTheFirstLineAfterTheSignOffIsRead() {
        let text = "Thank you,\n\nMarcus Bellamy\nDelia Hartwell"
        #expect(Self.closings(in: text).map(\.text) == ["Marcus Bellamy"])
        let upper = "sincerely,\nDELIA HARTWELL\nCounsel for Plaintiff"
        #expect(Self.closings(in: upper).map(\.text) == ["DELIA HARTWELL"])
    }

    @Test("Two letters on one page each surface their own signer")
    func twoLettersEachSurfaceTheirSigner() {
        let text = "Sincerely,\nDelia Hartwell\n\nSecond letter follows.\n\nRegards,\n\nMarcus Bellamy, Esq.\n"
        #expect(Self.closings(in: text).map(\.text) == ["Delia Hartwell", "Marcus Bellamy"])
    }
}
