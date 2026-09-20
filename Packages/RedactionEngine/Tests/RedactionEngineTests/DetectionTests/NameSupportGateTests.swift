import Testing
import Foundation
@testable import RedactionEngine

// The first-pass inventory-support gate: a mixed-case name candidate the
// tagger surfaces on the first (non-strict) pass is dropped when the name
// inventory does not SUPPORT it — no exact surname hit that is not a curated
// common word, no fuzzy hit, and (for a lone token) no given-name
// membership. It is the mirror of the strict pass's existing gate. The
// prefix pass is untouched, and the strict (ALL-CAPS shadow) pass keeps
// reading `hadAnyHit`, so its hit set does not move.
//
// Fixtures: the golden-1000 surname filter (members: smith, jones, garcia,
// lopez, james) where support is wanted, and an all-zero filter (built here
// from the RSBF header) where NO support is wanted — the fuzzy path probes
// hundreds of one-edit variants, so a small real filter's own collision rate
// cannot be relied on for a "no neighbour" claim; an empty bit array can.
// The given-name filter is the empty one unless a test says otherwise, so a
// surname is never also a "given name" by fixture accident. The tagger half
// is gated on the OS-provisioned `.nameType` NER asset
// (`PIIDetector.isNameNERAvailable()`; the detection harness pin is iOS
// 26.4), following the NameStopTokenTests skip pattern.
//
// Synthetic Hartwell/Sablebrook cast only (repo test-data policy).

@Suite("Name first-pass inventory-support gate (the pair with common-word curation)")
struct NameSupportGateTests {

    private static func skipNER(_ test: String) {
        print("[NLTagger gate] .nameType NER asset unavailable on this runtime; "
              + "skipping \(test) (harness pin = iOS 26.4).")
    }

    private static func goldenFilter() throws -> BloomFilter {
        let url = try #require(Bundle.module.url(forResource: "golden-1000",
                                                 withExtension: "bloom",
                                                 subdirectory: "TestResources"))
        return try BloomFilter(data: Data(contentsOf: url))
    }

    /// An RSBF filter whose bit array is all zeros: `contains` is false for
    /// every key, on the exact path and on every fuzzy variant.
    private static func emptyFilter() throws -> BloomFilter {
        var bytes = Data("RSBF".utf8)
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
        le(BloomFilter.currentVersion)      // version u16
        bytes.append(1)                     // k u8
        le(UInt64(64))                      // m u64 (bits)
        le(UInt64(0))                       // seed
        le(UInt64(0))                       // row count
        bytes.append(Data(repeating: 0, count: 32))   // source hash
        bytes.append(Data(repeating: 0, count: 8))    // 64 zero bits
        #expect(bytes.count == BloomFilter.headerSize + 8)
        return try BloomFilter(data: bytes)
    }

    private static func detector(surnames: BloomFilter, givenNames: BloomFilter? = nil,
                                 curating words: [String] = []) throws -> PIIDetector {
        let gazetteer = NameGazetteer(surnameFilter: surnames,
                                      givenNameFilter: try givenNames ?? emptyFilter(),
                                      commonWords: NameCommonWords(words: words))
        return PIIDetector(nameGazetteer: gazetteer)
    }

    private static func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    private static func hits(_ matches: [PIIDetector.PIIMatch], covering needle: String, in text: String)
        -> [PIIDetector.PIIMatch] {
        let r = Self.range(of: needle, in: text)
        return matches.filter { NSIntersectionRange($0.range, r).length > 0 }
    }

    private static func summary(_ hits: [PIIDetector.PIIMatch]) -> String {
        hits.map { "\($0.text)@\($0.confidence)" }.joined(separator: ", ")
    }

    // MARK: - The gate

    @Test("An unsupported Title-case pair is dropped on the first pass")
    func unsupportedPairDropped() throws {
        guard PIIDetector.isNameNERAvailable() else { Self.skipNER("unsupportedPairDropped"); return }
        let text = "Delia Hartwell signed the intake form on Tuesday."
        let d = try Self.detector(surnames: Self.emptyFilter())
        let hits = Self.hits(d.detectNames(in: text), covering: "Delia Hartwell", in: text)
        #expect(hits.isEmpty, "an inventory-unsupported name must not surface on the tagger's word alone: \(Self.summary(hits))")
    }

    @Test("A supported pair is kept with its boost")
    func supportedPairKept() throws {
        guard PIIDetector.isNameNERAvailable() else { Self.skipNER("supportedPairKept"); return }
        let text = "James Garcia signed the intake form on Tuesday."
        let d = try Self.detector(surnames: Self.goldenFilter())
        let hits = Self.hits(d.detectNames(in: text), covering: "Garcia", in: text)
        #expect(hits.contains { $0.confidence > 0.75 }, "the surname credit is applied: \(Self.summary(hits))")
    }

    @Test("A lone given-name token stays (the given-name fallback, as on the strict pass)")
    func loneGivenNameKept() throws {
        guard PIIDetector.isNameNERAvailable() else { Self.skipNER("loneGivenNameKept"); return }
        // No surname support at all; "james" is a member of the given-name
        // filter only → the lone token surfaces at the base score.
        let text = "Please forward the packet to James before noon."
        let d = try Self.detector(surnames: Self.emptyFilter(), givenNames: Self.goldenFilter())
        let hits = Self.hits(d.detectNames(in: text), covering: "James", in: text)
        #expect(hits.contains { $0.confidence == 0.70 }, "the lone given name is kept at the base score: \(Self.summary(hits))")
        let none = try Self.detector(surnames: Self.emptyFilter())
        #expect(Self.hits(none.detectNames(in: text), covering: "James", in: text).isEmpty,
                "and without given-name membership it is dropped")
    }

    @Test("A curated common-word surname loses its credit and, unsupported, is dropped on the first pass")
    func commonWordSurnameDropped() throws {
        guard PIIDetector.isNameNERAvailable() else { Self.skipNER("commonWordSurnameDropped"); return }
        let text = "James Garcia signed the intake form on Tuesday."
        let plain = Self.hits(try Self.detector(surnames: Self.goldenFilter()).detectNames(in: text),
                              covering: "Garcia", in: text)
        #expect(plain.contains { $0.confidence > 0.75 }, "without the curation the surname earns credit: \(Self.summary(plain))")
        let curated = Self.hits(try Self.detector(surnames: Self.goldenFilter(), curating: ["garcia"]).detectNames(in: text),
                                covering: "Garcia", in: text)
        #expect(curated.isEmpty, "a curated surname with no other support is dropped: \(Self.summary(curated))")
    }

    // MARK: - What the gate must not touch

    @Test("The prefix pass is untouched: a name after a role noun surfaces without inventory support")
    func prefixPassUntouched() throws {
        let text = "Plaintiff Delia Hartwell moved for summary judgment."
        let d = try Self.detector(surnames: Self.emptyFilter())
        let hits = Self.hits(d.detectNames(in: text), covering: "Delia Hartwell", in: text)
        #expect(hits.contains { $0.confidence == 0.65 }, "the prefix pass yields the name at its own confidence: \(Self.summary(hits))")
    }

    @Test("The strict ALL-CAPS pass is unchanged: unsupported dropped, supported kept, a curated member kept and demoted")
    func strictPassUnchanged() throws {
        guard PIIDetector.isNameNERAvailable() else { Self.skipNER("strictPassUnchanged"); return }
        let unsupported = "DELIA HARTWELL signed the intake form on Tuesday."
        let dropped = Self.hits(try Self.detector(surnames: Self.emptyFilter()).detectNames(in: unsupported),
                                covering: "DELIA HARTWELL", in: unsupported)
        #expect(dropped.isEmpty, Comment(rawValue: Self.summary(dropped)))
        let supported = "JAMES GARCIA signed the intake form on Tuesday."
        let kept = Self.hits(try Self.detector(surnames: Self.goldenFilter()).detectNames(in: supported),
                             covering: "GARCIA", in: supported)
        #expect(!kept.isEmpty, "a supported ALL-CAPS name still surfaces")
        // A curated member the filter carries: the strict pass keeps reading
        // the membership (hit set unchanged) and the credit is withheld.
        let member = Self.hits(try Self.detector(surnames: Self.goldenFilter(), curating: ["garcia"]).detectNames(in: supported),
                               covering: "GARCIA", in: supported)
        #expect(!member.isEmpty, "the strict pass's hit set does not move for a member the filter carries")
        #expect(member.allSatisfy { $0.confidence <= 0.70 }, "and the credit is withheld: \(Self.summary(member))")
    }

    @Test("Without a gazetteer the gate is inert (stripped-bundle behaviour unchanged)")
    func noGazetteerInert() {
        guard PIIDetector.isNameNERAvailable() else { Self.skipNER("noGazetteerInert"); return }
        let text = "Delia Hartwell signed the intake form on Tuesday."
        let hits = Self.hits(PIIDetector(nameGazetteer: nil).detectNames(in: text), covering: "Delia Hartwell", in: text)
        #expect(!hits.isEmpty, "with no inventory the tagger's word stands, as before")
    }
}
