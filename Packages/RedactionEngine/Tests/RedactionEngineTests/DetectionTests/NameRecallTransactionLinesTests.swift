import Testing
import Foundation
import NaturalLanguage
import PDFKit
@testable import RedactionEngine

// FIX-DESIGN Part B (P1) — name recall on transaction lines + per-occurrence
// range anchoring.
//
// Two compounding defects left repeated / label-glued account-holder names
// unredacted:
//   B1 (recall)      — the Pass-2 shadow split on single spaces only, so a
//                      label-glued token (`INDN:DELIA`) title-cased to
//                      `Indn:delia` and NLTagger never saw the name; the
//                      strict gazetteer gate also queried lone tokens as
//                      surnames only, so given-name words could be
//                      suppressed even when tagged.
//   B2 (multiplicity) — the range resolver re-located every tagger hit via a
//                      from-zero `range(of:)`, so N occurrences of the same
//                      name collapsed to the first occurrence's range and
//                      `deduplicateByRange` kept them collapsed.
//
// Section A exercises the `nerShadow` transformation itself (deterministic,
// environment-independent). Section B drives the detector through NLTagger
// and is gated on the OS-provisioned `.nameType` NER asset
// (`PIIDetector.isNameNERAvailable()`, reliably provisioned on iOS 26.4 —
// the detection harness pin) plus the bundled name gazetteer, following the
// NameGazetteerIntegrationTests skip pattern.
//
// Synthetic Hartwell/Sablebrook cast only (repo test-data policy). The
// packet fixture is fully synthetic with a public values manifest, so
// matched text may be logged here (D31 exemption, as in PacketSnapshotTests).
//
// Privacy rule (audit-lint M-1): comments and test names use
// locate/surface/resolve vocabulary.

@Suite("Name recall on transaction lines + per-occurrence anchoring (Part B)")
struct NameRecallTransactionLinesTests {

    // MARK: - Helpers

    private static func nerAvailable() -> Bool {
        PIIDetector.isNameNERAvailable()
    }

    private static func skipNER(_ test: String) {
        print("[NLTagger gate] .nameType NER asset unavailable on this runtime; "
              + "skipping \(test) (REDACTION_ENGINE.md §4.5; harness pin = iOS 26.4).")
    }

    /// Every occurrence of `word` in `text` as an NSRange.
    private static func occurrences(of word: String, in text: String) -> [NSRange] {
        let ns = text as NSString
        var result: [NSRange] = []
        var cursor = NSRange(location: 0, length: ns.length)
        while true {
            let found = ns.range(of: word, options: [], range: cursor)
            guard found.location != NSNotFound else { break }
            result.append(found)
            let next = NSMaxRange(found)
            cursor = NSRange(location: next, length: ns.length - next)
        }
        return result
    }

    /// True when every character position of `span` lies inside at least one
    /// name-match range.
    private static func covered(
        _ span: NSRange, by matches: [PIIDetector.PIIMatch]
    ) -> Bool {
        var pos = span.location
        let end = NSMaxRange(span)
        while pos < end {
            guard let match = matches.first(
                where: { NSLocationInRange(pos, $0.range) }) else { return false }
            pos = max(pos + 1, NSMaxRange(match.range))
        }
        return true
    }

    // MARK: - Section A: nerShadow transformation (environment-independent)

    @Test("Shadow segments label-glued tokens into tagger-visible words")
    func shadowSegmentsLabelGluedTokens() {
        #expect(PIIDetector.nerShadow("INDN:DELIA HARTWELL CO ID:1364419872")
                == "Indn Delia Hartwell Co Id 1364419872")
        #expect(PIIDetector.nerShadow("PAYMENT TO DELIA HARTWELL,CHECKING")
                == "Payment To Delia Hartwell Checking")
        // Legacy behavior on the same input (documents why the shadow
        // replaced it): the glued name never surfaced as a taggable word.
        #expect(PIIDetector.titleCaseAllCapsWords("INDN:DELIA HARTWELL CO ID:1364419872")
                == "Indn:delia Hartwell Co Id:1364419872")
    }

    @Test("Shadow matches legacy title-casing on plain ALL-CAPS text")
    func shadowMatchesLegacyOnPlainAllCaps() {
        let text = "JOHN SMITH FILED A CLAIM"
        #expect(PIIDetector.nerShadow(text) == "John Smith Filed A Claim")
        #expect(PIIDetector.nerShadow(text) == PIIDetector.titleCaseAllCapsWords(text))
    }

    @Test("Shadow preserves UTF-16 length across edge cases",
          arguments: [
            "INDN:DELIA HARTWELL CO ID:1364419872",
            "DELIA  HARTWELL   third:  run",          // space runs (legacy collapsed these)
            "ACME CORP\nDELIA HARTWELL\tOWNER",       // newline + tab boundaries
            "ÉLODIE MARCHAND: COMPTE",                // non-ASCII uppercase (1:1 case map)
            "İSTANBUL BRANCH: ID",                    // uppercase İ leads a word
            "DİYARBAKIR BRANCH: ID",                  // mid-word İ lowercases to 2 units — skipped
            "STRASSE ß TEST: OK",                     // ß uppercases to SS; lowercase is 1:1 no-op
            "A/B TEST 🙂 EMOJI:CASE",                 // emoji + separators
            "",                                        // empty
            " :;,/ ",                                  // separators only
          ])
    func shadowPreservesUTF16Length(_ text: String) {
        let shadow = PIIDetector.nerShadow(text)
        #expect(shadow.utf16.count == text.utf16.count,
                "shadow must be UTF-16 length-preserving for offset anchoring")
    }

    @Test("Shadow changes are limited to case folds and separator substitution")
    func shadowChangesAreCaseOrSeparatorOnly() {
        let separators: Set<Character> = [":", ";", ",", "/"]
        let battery = [
            "INDN:DELIA HARTWELL CO ID:1364419872",
            "ACME CORP\nDELIA HARTWELL\tOWNER",
            "MARY-JANE O'BRIEN / ACCOUNT;OWNER",
            "Mixed Case stays, MOSTLY: intact",
        ]
        for text in battery {
            let original = Array(text)
            let shadow = Array(PIIDetector.nerShadow(text))
            #expect(original.count == shadow.count)
            for (o, s) in zip(original, shadow) where o != s {
                let isSeparatorSub = separators.contains(o) && s == " "
                let isCaseFold = String(s) == String(o).lowercased()
                #expect(isSeparatorSub || isCaseFold,
                        "unexpected shadow edit: \(o) -> \(s) in \(text)")
            }
        }
    }

    @Test("Shadow treats newlines as word boundaries")
    func shadowNewlineIsBoundary() {
        #expect(PIIDetector.nerShadow("ACME CORP\nDELIA HARTWELL")
                == "Acme Corp\nDelia Hartwell")
    }

    @Test("Shadow keeps whitelisted acronyms and mixed-case words intact")
    func shadowKeepsAcronymsAndMixedCase() {
        #expect(PIIDetector.nerShadow("FBI AGENT SSN: 123") == "FBI Agent SSN  123")
        #expect(PIIDetector.nerShadow("Hello World test") == "Hello World test")
        #expect(PIIDetector.nerShadow("IRS FORM") == "IRS Form")
    }

    @Test("Shadow keeps the first letter of each letter run uppercase")
    func shadowUppercasesLetterRunStarts() {
        #expect(PIIDetector.nerShadow("MARY-JANE O'BRIEN") == "Mary-Jane O'Brien")
        #expect(PIIDetector.nerShadow("U.S. BANK STATEMENT") == "U.S. Bank Statement")
    }

    // MARK: - Section B: detector recall + anchoring (NER-gated)

    /// The B1 recall battery: the observed leak shape plus realistic
    /// transaction-line variants (all-caps, colon-glued, NAME: prefix,
    /// trailing codes, comma-glued).
    @Test("Detector surfaces DELIA HARTWELL on transaction-line variants",
          arguments: [
            "INDN:DELIA HARTWELL CO ID:1364419872",
            "INDN: DELIA HARTWELL DES: PAYROLL",
            "NAME:DELIA HARTWELL ACCT 4421",
            "ACH DEBIT DES:WEB PMT INDN:DELIA HARTWELL CO ID:9210001 WEB",
            "PAYMENT TO DELIA HARTWELL,CHECKING 05/31/2026",
          ])
    func b1RecallTransactionVariants(_ line: String) throws {
        #if !os(iOS)
        // macOS tooling destination: the host NLTagger name model differs
        // from the pinned iOS 26.4 runtime and misses some variants; this
        // recall battery is iOS-normative.
        print("[macOS tooling] b1RecallTransactionVariants: iOS-normative; skipping.")
        return
        #else
        guard Self.nerAvailable() else { Self.skipNER(#function); return }
        guard NameGazetteer() != nil else {
            print("[W2 gate] NameGazetteer bundle missing; skipping bundled test.")
            return
        }
        let detector = PIIDetector()
        let names = detector.detectNames(in: line).filter { $0.kind == .name }

        for word in ["DELIA", "HARTWELL"] {
            let spans = Self.occurrences(of: word, in: line)
            #expect(!spans.isEmpty)
            for span in spans {
                #expect(Self.covered(span, by: names),
                        "\(word) at \(span) uncovered in: \(line)")
            }
        }
        #endif
    }

    /// The B2 anti-collapse regression: the SAME name at three distinct
    /// offsets must yield three distinct detection ranges (pre-fix, all
    /// three resolved to the first occurrence and deduplicated to one box).
    @Test("Same name at three offsets yields three distinct ranges")
    func b2SameNameThreeOffsetsYieldsThreeRanges() throws {
        guard Self.nerAvailable() else { Self.skipNER(#function); return }
        guard NameGazetteer() != nil else {
            print("[W2 gate] NameGazetteer bundle missing; skipping bundled test.")
            return
        }
        let page = """
            INDN:DELIA HARTWELL CO ID:1364419872
            INDN:DELIA HARTWELL CO ID:2200457810
            INDN: DELIA HARTWELL DES: PAYROLL
            """
        let detector = PIIDetector()
        let names = detector.detectNames(in: page).filter { $0.kind == .name }

        for word in ["DELIA", "HARTWELL"] {
            let spans = Self.occurrences(of: word, in: page)
            #expect(spans.count == 3)
            for span in spans {
                #expect(Self.covered(span, by: names),
                        "\(word) occurrence at \(span) uncovered")
            }
            // Distinctness: the matches covering this word anchor at three
            // different locations (the collapse yielded exactly one).
            let coveringLocations = Set(
                names.filter { match in
                    spans.contains { NSIntersectionRange($0, match.range).length > 0 }
                }.map(\.range.location)
            )
            #expect(coveringLocations.count >= 3,
                    "\(word) matches collapsed to \(coveringLocations.count) location(s)")
        }
    }

    /// Offset-map correctness: the emitted range indexes the ORIGINAL
    /// (all-caps) string — the off-by-one on the title-case shadow is the
    /// classic failure — and the match text carries the original casing.
    @Test("Emitted ranges resolve to the original ALL-CAPS text")
    func rangeMapsToOriginalAllCapsText() throws {
        guard Self.nerAvailable() else { Self.skipNER(#function); return }
        guard NameGazetteer() != nil else {
            print("[W2 gate] NameGazetteer bundle missing; skipping bundled test.")
            return
        }
        let line = "INDN:DELIA HARTWELL CO ID:1364419872"
        let ns = line as NSString
        let detector = PIIDetector()
        let names = detector.detectNames(in: line).filter { $0.kind == .name }
        #expect(!names.isEmpty)

        for match in names {
            #expect(NSMaxRange(match.range) <= ns.length)
            #expect(ns.substring(with: match.range) == match.text,
                    "match text must be the original substring at its range")
        }
        let delia = names.first { NSIntersectionRange($0.range, ns.range(of: "DELIA")).length > 0 }
        #expect(delia?.text == "DELIA",
                "the covering match must carry the original ALL-CAPS casing")
    }

    /// W2 strict-gate preservation: candidates absent from BOTH blooms stay
    /// suppressed on the shadow pass (the gate widening is given-bloom-only).
    @Test("Strict shadow pass still suppresses unknown-cast candidates")
    func strictShadowPassStillSuppressesUnknownCast() throws {
        guard Self.nerAvailable() else { Self.skipNER(#function); return }
        guard let gazetteer = NameGazetteer() else {
            print("[W2 gate] NameGazetteer bundle missing; skipping bundled test.")
            return
        }
        // 'korrin' / 'sablebrook' are in neither the surname nor the
        // given-name source list (fictional cast, verified against the
        // datapipeline ingest caches).
        let line = "INDN:KORRIN SABLEBROOK CO ID:1364419872"
        let detector = PIIDetector(nameGazetteer: gazetteer)
        let names = detector.detectNames(in: line).filter {
            $0.kind == .name && (
                $0.text.lowercased().contains("korrin")
                || $0.text.lowercased().contains("sablebrook")
            )
        }
        #expect(names.isEmpty,
                "strict pass must keep suppressing candidates unknown to both blooms")
    }

    /// B1 gate shape: a given-name-only word (present in the given bloom,
    /// absent from the surname source list) surfaces via the widened strict
    /// gate with the bloomGivenHit signal at baseline confidence.
    @Test("Given-name-only candidate surfaces via the given bloom")
    func givenNameOnlyCandidateSurfacesViaGivenBloom() throws {
        guard Self.nerAvailable() else { Self.skipNER(#function); return }
        guard NameGazetteer() != nil else {
            print("[W2 gate] NameGazetteer bundle missing; skipping bundled test.")
            return
        }
        // 'katelyn': SSA given-name list yes; census surname list no
        // (verified against the datapipeline ingest caches).
        let line = "INDN:KATELYN HARTWELL CO ID:1364419872"
        let ns = line as NSString
        let detector = PIIDetector()
        let names = detector.detectNames(in: line).filter { $0.kind == .name }

        let katelyn = names.first {
            NSIntersectionRange($0.range, ns.range(of: "KATELYN")).length > 0
        }
        #expect(katelyn != nil, "given-name-only candidate must not be gate-suppressed")
        if let katelyn, let rationale = katelyn.rationale {
            #expect(rationale.signals.contains(.bloomGivenHit),
                    "the widened gate records its given-bloom evidence")
        }
    }

    // MARK: - Packet fixture measurement (before/after evidence for Part B)

    /// Measurement on the synthetic packet's ACH page (page 8), which carries
    /// the account-holder name at four offsets (one mixed-case header, two
    /// INDN transaction lines, one printed-name line). Pre-fix the resolver
    /// collapsed these onto the first occurrence. Prints the per-occurrence
    /// map for the PR body; hard assertion is the anti-collapse floor.
    @Test("Packet ACH page: name occurrences anchor per-occurrence")
    func packetACHPageNameMeasurement() async throws {
        guard Self.nerAvailable() else { Self.skipNER(#function); return }
        guard NameGazetteer() != nil else {
            print("[W2 gate] NameGazetteer bundle missing; skipping bundled test.")
            return
        }
        let data = try TestFixtures.loanPacketPDF()
        let document = try #require(PDFDocument(data: data))
        let page = try #require(document.page(at: 8))
        let text = try #require(EmbeddedTextSource.make(from: page)).text
        let ns = text as NSString

        let detector = PIIDetector()
        let names = detector.detectNames(in: text).filter { $0.kind == .name }

        let surnameSpans = Self.occurrences(of: "HARTWELL", in: text)
            + Self.occurrences(of: "Hartwell", in: text)
        let coveredSpans = surnameSpans.filter { Self.covered($0, by: names) }
        print("[P1-PartB] packet p8: surname occurrences=\(surnameSpans.count) "
              + "covered=\(coveredSpans.count) nameMatches=\(names.count) "
              + "distinctLocations=\(Set(names.map(\.range.location)).count)")
        for match in names.sorted(by: { $0.range.location < $1.range.location }) {
            print("[P1-PartB]   name match loc=\(match.range.location) "
                  + "len=\(match.range.length) text=\(ns.substring(with: match.range))")
        }
        #expect(coveredSpans.count >= 3,
                "ACH-page repeats must anchor per-occurrence (pre-fix collapse covered at most 1)")
    }
}
