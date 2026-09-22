import Testing
import Foundation
@testable import RedactionEngine

// The label-anchor routes: deterministic readings of the name that sits in a
// document's label slots — a role or field label with its colon
// (`PLAINTIFF: …`, `Patient Name: …`) and the caption connector (`… v. …`).
// Each reading stays on one line, takes two or three capitalised tokens, and
// leaves a role noun, an honorific-led name (the prefix pass's shape) or an
// organisation alone. Every route match carries the same confidence as the
// prefix pass and a rationale whose signal names the route.
//
// Section A drives the pass on its own (`scanLabelAnchors`), apart from the
// tagger rows that win the overlap inside `detectNames` — deterministic, no
// NER asset involved. Section B reads the composed result of `detectNames`:
// the party is boxed, and never twice over the same text.
//
// Synthetic Hartwell/Sablebrook cast only (repo test-data policy).
//
// Privacy rule (audit-lint M-1): comments and test names use
// locate/surface/resolve vocabulary.

@Suite("Label anchor routes: role label + colon, caption")
struct LabelAnchorRouteTests {

    private static let ruleID = "name.label-anchor"

    /// The route matches for `text`, read from the pass on its own.
    private static func anchors(in text: String, doctype: DoctypeClass? = nil) -> [PIIDetector.PIIMatch] {
        PIIDetector().scanLabelAnchors(in: text, doctype: doctype)
    }

    private static func names(in text: String, doctype: DoctypeClass? = nil) -> [PIIDetector.PIIMatch] {
        PIIDetector().detectNames(in: text, doctype: doctype)
    }

    private static func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    private static func overlaps(_ matches: [PIIDetector.PIIMatch], _ range: NSRange) -> Bool {
        matches.contains { NSIntersectionRange($0.range, range).length > 0 }
    }

    private static func routeSignal(_ match: PIIDetector.PIIMatch) -> String? {
        for signal in match.rationale?.signals ?? [] {
            if case .regexPattern(let name) = signal, name.hasPrefix(ruleID + ".") {
                return String(name.dropFirst(ruleID.count + 1))
            }
        }
        return nil
    }

    // MARK: - A. Route 1a: a role or field label with its colon

    @Test("An upper-case role label with a colon surfaces the name after it")
    func upperCaseRoleLabelWithColonSurfacesTheName() {
        let text = "PLAINTIFF: Marcus Bellamy"
        let hits = Self.anchors(in: text)
        #expect(hits.count == 1)
        #expect(hits.first?.text == "Marcus Bellamy")
        #expect(hits.first.map { $0.range == Self.range(of: "Marcus Bellamy", in: text) } == true)
        #expect(hits.first.map(Self.routeSignal) == "label-colon")
    }

    @Test("The label reads case-folded: title case, lower case and upper case surface the same name")
    func labelReadsCaseFolded() {
        for text in ["Defendant: Delia Hartwell", "defendant: Delia Hartwell", "DEFENDANT: Delia Hartwell",
                     "Defendant : Delia Hartwell", "Defendant:Delia Hartwell"] {
            let hits = Self.anchors(in: text)
            #expect(hits.map(\.text) == ["Delia Hartwell"], "in \(text.debugDescription)")
        }
    }

    @Test("A label from the shipped name positives reads with the document's doctype")
    func assetLabelReadsWithTheDoctype() throws {
        _ = try ContextKeywordsLoader()
        let text = "Patient Name: Delia Hartwell"
        let withDoctype = Self.anchors(in: text, doctype: .medical)
        #expect(withDoctype.map(\.text) == ["Delia Hartwell"])
        // Out of scope for the doctype, or with no doctype at all, the label
        // is not in the vocabulary and the route stays quiet.
        #expect(Self.anchors(in: text, doctype: .court).isEmpty)
        #expect(Self.anchors(in: text).isEmpty)
        // The court role words are court-scoped rows; `petitioner` lives in
        // the asset only.
        let petitioner = "Petitioner: Marcus Bellamy"
        #expect(Self.anchors(in: petitioner, doctype: .court).map(\.text) == ["Marcus Bellamy"])
        #expect(Self.anchors(in: petitioner).isEmpty)
    }

    @Test("The reading stays on the label's own line")
    func readingStaysOnTheLabelLine() {
        let stacked = "PLAINTIFF:\nDelia Hartwell"
        #expect(Self.anchors(in: stacked).isEmpty)

        let twoLines = "Defendant.\n\nPLAINTIFF: Marcus Bellamy\nDelia Hartwell"
        let hits = Self.anchors(in: twoLines)
        #expect(hits.map(\.text) == ["Marcus Bellamy"])
        #expect(!Self.overlaps(hits, Self.range(of: "Delia Hartwell", in: twoLines)))

        let crlf = "PLAINTIFF: Marcus Bellamy\r\nDEFENDANT: Delia Hartwell\r\n"
        #expect(Set(Self.anchors(in: crlf).map(\.text)) == ["Marcus Bellamy", "Delia Hartwell"])
    }

    @Test("The label is token-bounded: a longer word that contains it is not a label")
    func labelIsTokenBounded() {
        #expect(Self.anchors(in: "Codefendant: Marcus Bellamy").isEmpty)
        #expect(Self.anchors(in: "Plaintiffs: Marcus Bellamy").isEmpty)
        #expect(Self.anchors(in: "Plaintiff2: Marcus Bellamy").isEmpty)
    }

    @Test("A role noun in prose, with no colon, reads nothing")
    func roleNounInProseReadsNothing() {
        #expect(Self.anchors(in: "Plaintiff is a corporation, Business Registration # 4432.").isEmpty)
        #expect(Self.anchors(in: "Defendant reserves all rights.").isEmpty)
        #expect(Self.anchors(in: "Plaintiff Marcus Bellamy moved for summary judgment.").isEmpty)
    }

    @Test("A role noun, an honorific-led name or a placeholder after the colon is not read")
    func roleNounHonorificOrPlaceholderAfterTheColonIsNotRead() {
        #expect(Self.anchors(in: "Plaintiff: Defendant").isEmpty)
        #expect(Self.anchors(in: "Plaintiff: Defendant Marcus Bellamy").isEmpty)
        #expect(Self.anchors(in: "PLAINTIFF: [REDACTED]").isEmpty)
        // The honorific-led shape belongs to the prefix pass.
        #expect(Self.anchors(in: "Defendant: Mr. Marcus Bellamy").isEmpty)
        // A lower-case continuation is prose, not a name.
        #expect(Self.anchors(in: "Defendant: the corporation named above").isEmpty)
        // A digit or a symbol right after the colon is a value, not a name.
        #expect(Self.anchors(in: "Witness: 2 Marcus Bellamy").isEmpty)
    }

    @Test("A single token after the label is not read as a name")
    func singleTokenAfterTheLabelIsNotRead() {
        #expect(Self.anchors(in: "Plaintiff: Sablebrook").isEmpty)
        #expect(Self.anchors(in: "Plaintiff: Bellamy, individually").isEmpty)
    }

    @Test("A comma ends the candidate; at most three tokens are read")
    func commaEndsTheCandidateAndThreeTokensIsTheMost() {
        let comma = Self.anchors(in: "PLAINTIFF: Marcus Bellamy, individually and on behalf of others")
        #expect(comma.map(\.text) == ["Marcus Bellamy"])
        let long = Self.anchors(in: "PLAINTIFF: Marcus Bellamy Hartwell Delia Sablebrook")
        #expect(long.map(\.text) == ["Marcus Bellamy Hartwell"])
        let suffix = Self.anchors(in: "Attorney: Delia Hartwell, Esq.")
        #expect(suffix.map(\.text) == ["Delia Hartwell"])
    }

    @Test("A sentence period after the name stays outside the box; an initial keeps its period")
    func sentencePeriodStaysOutsideTheBox() {
        let sentence = "Witness: Delia Hartwell."
        #expect(Self.anchors(in: sentence).map(\.text) == ["Delia Hartwell"])
        let initial = "Witness: Delia J. Hartwell"
        #expect(Self.anchors(in: initial).map(\.text) == ["Delia J. Hartwell"])
        let hyphen = "Witness: Delia Hartwell-Bellamy"
        #expect(Self.anchors(in: hyphen).map(\.text) == ["Delia Hartwell-Bellamy"])
    }

    @Test("An organisation after the label is left alone")
    func organisationAfterTheLabelIsLeftAlone() {
        #expect(Self.anchors(in: "DEFENDANT: Sablebrook Holdings Inc.").isEmpty)
        #expect(Self.anchors(in: "Plaintiff: The City of Sablebrook").isEmpty)
        #expect(Self.anchors(in: "Defendant: Sablebrook County Hospital").isEmpty)
    }

    // MARK: - A. Route 1b: the caption connector

    @Test("A caption surfaces the party on each side of the connector when both are people")
    func captionSurfacesBothPartiesWhenBothArePeople() {
        let text = "Marcus Bellamy v. Delia Hartwell"
        let hits = Self.anchors(in: text)
        #expect(hits.count == 2)
        #expect(Set(hits.map(\.text)) == ["Marcus Bellamy", "Delia Hartwell"])
        #expect(hits.allSatisfy { Self.routeSignal($0) == "caption" })
        #expect(hits.contains { $0.range == Self.range(of: "Marcus Bellamy", in: text) })
        #expect(hits.contains { $0.range == Self.range(of: "Delia Hartwell", in: text) })
        // The other connector spelling and an upper-case caption read the same.
        #expect(Set(Self.anchors(in: "Marcus Bellamy vs. Delia Hartwell").map(\.text)) == ["Marcus Bellamy", "Delia Hartwell"])
        #expect(Set(Self.anchors(in: "MARCUS BELLAMY V. DELIA HARTWELL").map(\.text)) == ["MARCUS BELLAMY", "DELIA HARTWELL"])
    }

    @Test("A caption leaves the organisation side alone")
    func captionLeavesTheOrganisationAlone() {
        let text = "Marcus Bellamy v. Sablebrook Holdings Inc."
        let hits = Self.anchors(in: text)
        #expect(hits.map(\.text) == ["Marcus Bellamy"])
        #expect(!Self.overlaps(hits, Self.range(of: "Sablebrook Holdings", in: text)))

        let reversed = "Sablebrook County v. Delia Hartwell"
        #expect(Self.anchors(in: reversed).map(\.text) == ["Delia Hartwell"])
    }

    @Test("The caption reads the tokens next to the connector only, and never across a line")
    func captionReadsNextToTheConnectorOnly() {
        let prose = "the estate of Marcus Bellamy v. Delia Hartwell, individually"
        let hits = Self.anchors(in: prose)
        #expect(Set(hits.map(\.text)) == ["Marcus Bellamy", "Delia Hartwell"])

        let stacked = "Marcus Bellamy,\nPlaintiff,\nv.\nDelia Hartwell,\nDefendant."
        #expect(Self.anchors(in: stacked).isEmpty)
    }

    @Test("A single-token party is not read from the caption; the connector needs whitespace on both sides")
    func singleTokenPartyIsNotReadFromTheCaption() {
        #expect(Self.anchors(in: "Bellamy v. Hartwell").isEmpty)
        #expect(Self.anchors(in: "Marcus Bellamy v.Delia Hartwell").isEmpty)
        #expect(Self.anchors(in: "Marcus Bellamyv. Delia Hartwell").isEmpty)
    }

    // MARK: - A. The match every route produces

    @Test("A route match carries the prefix pass's confidence and a rationale naming the route")
    func routeMatchCarriesConfidenceAndRationale() throws {
        let hits = Self.anchors(in: "PLAINTIFF: Marcus Bellamy")
        let hit = try #require(hits.first)
        #expect(hit.confidence == 0.65)
        #expect(hit.confidence == PIIDetector.labelAnchorConfidence)
        #expect(hit.rationale?.ruleID == Self.ruleID)
        #expect(hit.rationale?.preThresholdScore == 0.65)
        #expect(hit.rationale?.finalScore == 0.65)
        #expect(hit.rationale?.signals == [.regexPattern(name: "name.label-anchor.label-colon")])
        #expect(RuleCatalog.knownEngineRuleIDs.contains(Self.ruleID))
    }

    @Test("The organisation marker set is case-folded and period-free")
    func organisationMarkerSetIsCaseFoldedAndPeriodFree() {
        for marker in PIIDetector.organizationMarkers {
            #expect(marker == marker.lowercased())
            #expect(!marker.hasSuffix("."))
        }
        #expect(PIIDetector.organizationMarkers.isSuperset(of: ["inc", "corp", "llc", "county"]))
    }

    @Test("An empty page and a page with no label read nothing")
    func emptyPageReadsNothing() {
        #expect(Self.anchors(in: "").isEmpty)
        #expect(Self.anchors(in: "\n\n").isEmpty)
        #expect(Self.anchors(in: "Total due: 1,204.00\nAccount ending 4432").isEmpty)
    }

    // MARK: - B. Composed with the tagger and the prefix pass

    @Test("Through detectNames the party after an upper-case label is boxed, and never twice over the same text")
    func composedResultBoxesThePartyOnce() {
        let text = "PLAINTIFF: Marcus Bellamy"
        let hits = Self.names(in: text)
        let nameRange = Self.range(of: "Marcus Bellamy", in: text)
        #expect(Self.overlaps(hits, nameRange))
        // No two boxes overlap (the route yields to a tagger row on the same text).
        for (i, a) in hits.enumerated() {
            for b in hits.dropFirst(i + 1) {
                #expect(NSIntersectionRange(a.range, b.range).length == 0)
            }
        }
        #expect(!hits.contains { $0.text == "PLAINTIFF" || $0.text == "Plaintiff" })
    }

    @Test("Through detectNames a caption's organisation side stays unboxed by the route")
    func composedResultLeavesTheOrganisationToOtherPasses() {
        let text = "Marcus Bellamy v. Sablebrook Holdings Inc."
        let hits = Self.names(in: text).filter { $0.rationale?.ruleID == Self.ruleID }
        #expect(!Self.overlaps(hits, Self.range(of: "Sablebrook Holdings", in: text)))
    }
}
