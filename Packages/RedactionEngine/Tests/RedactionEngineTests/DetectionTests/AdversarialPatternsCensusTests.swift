import Foundation
import Testing
@testable import RedactionEngine

// Census over the datapipeline-generated adversarial pattern fixture
// (Fixtures/adversarial/adversarial_patterns.json, `make adversarial` on the
// pipeline side). Every row's text runs through PIIDetector on the host and
// the outcome is tallied per category against the row's expectation. The
// tally is printed, not asserted: the fixture's expectations were authored
// against the 1.0-era detectors, so the table is a reading of where the
// detectors stand today, and a category that reads clean here is a
// candidate for a hard assertion in a later change. What this suite does
// assert is the fixture's shape — it decodes, has rows, unique ids, known
// detector families and known outcomes, and names its generator — so a
// pipeline-side change to the file's vocabulary fails here first.

@Suite("Adversarial pattern fixture census")
struct AdversarialPatternsCensusTests {

    struct Fixture: Decodable {
        let generated_by: String
        let seed: Int
        let version: Int
        let patterns: [Row]
    }

    struct Row: Decodable {
        let id: String
        let category: String
        let expected_detector: String
        let expected_outcome: String
        let source_plan_ref: String
        let text: String
    }

    /// The fixture's detector vocabulary mapped to the engine's categories.
    /// `none` (kept out of this map) marks a row that expects no family in
    /// particular: a document-level signal such as a keyword-stuffing stanza
    /// or a date collision, outside the per-text detector surface.
    private static let families: [String: PIICategory] = [
        "ssn": .ssn, "npi": .npi, "dea": .dea, "address": .address,
    ]
    private static let noFamily = "none"
    private static let outcomes: Set<String> = ["redact", "flag", "suppress"]

    private struct Tally {
        var rows = 0
        var honoured = 0
        var missed = 0
        var undecidable = 0
        var misses: [String] = []
    }

    private func loadFixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(
            forResource: "adversarial_patterns",
            withExtension: "json",
            subdirectory: "adversarial"
        ))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test("Every fixture row runs through the detector; the per-category tally is printed and the fixture's shape is asserted")
    func censusOverEveryRow() async throws {
        let fixture = try loadFixture()
        let rows = fixture.patterns

        // Well-formedness: the part that is asserted.
        #expect(!fixture.generated_by.isEmpty, "the fixture names its generator")
        #expect(!rows.isEmpty, "the fixture has rows")
        let ids = rows.map(\.id)
        #expect(Set(ids).count == ids.count, "row ids are unique")
        for row in rows {
            #expect(
                Self.families[row.expected_detector] != nil || row.expected_detector == Self.noFamily,
                "\(row.id): unknown expected_detector '\(row.expected_detector)'"
            )
            #expect(
                Self.outcomes.contains(row.expected_outcome),
                "\(row.id): unknown expected_outcome '\(row.expected_outcome)'"
            )
        }

        // The census: the part that is reported.
        let detector = PIIDetector()
        var tallies: [String: Tally] = [:]
        for row in rows {
            let fired = Set(await detector.detect(in: row.text).compactMap(\.category))
            var tally = tallies[row.category, default: Tally()]
            tally.rows += 1
            let family = Self.families[row.expected_detector]
            switch (row.expected_outcome, family) {
            case ("suppress", let family?):
                if fired.contains(family) {
                    tally.missed += 1
                    tally.misses.append("\(row.id) expected \(row.expected_detector) quiet, fired \(Self.describe(fired))")
                } else {
                    tally.honoured += 1
                }
            case ("suppress", nil):
                if fired.isEmpty {
                    tally.honoured += 1
                } else {
                    tally.missed += 1
                    tally.misses.append("\(row.id) expected nothing, fired \(Self.describe(fired))")
                }
            case (_, let family?):
                if fired.contains(family) {
                    tally.honoured += 1
                } else {
                    tally.missed += 1
                    tally.misses.append("\(row.id) expected \(row.expected_detector) to \(row.expected_outcome), fired \(Self.describe(fired))")
                }
            case (_, nil):
                // A fire-class outcome with no family is a document-level
                // expectation this surface cannot decide either way.
                tally.undecidable += 1
            }
            tallies[row.category] = tally
        }

        var honoured = 0, missed = 0, undecidable = 0
        for category in tallies.keys.sorted() {
            let tally = tallies[category]!
            honoured += tally.honoured
            missed += tally.missed
            undecidable += tally.undecidable
            print("[adversarial census] \(category): rows \(tally.rows) · honoured \(tally.honoured) · missed \(tally.missed) · undecidable \(tally.undecidable)")
            for miss in tally.misses {
                print("[adversarial census]     \(miss)")
            }
        }
        print("[adversarial census] total: rows \(rows.count) · honoured \(honoured) · missed \(missed) · undecidable \(undecidable) (fixture v\(fixture.version), seed \(fixture.seed), \(fixture.generated_by))")
    }

    private static func describe(_ fired: Set<PIICategory>) -> String {
        fired.isEmpty ? "nothing" : fired.map(\.rawValue).sorted().joined(separator: ", ")
    }
}
