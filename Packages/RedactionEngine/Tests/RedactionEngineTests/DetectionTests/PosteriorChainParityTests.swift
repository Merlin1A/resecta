import Foundation
import Testing
@testable import RedactionEngine

// The posterior chain's parity across its two homes.
//
// Site A (`DetectionOrchestrator.posterior(for:...)` — the Step 4 gate and
// the overlap resolver's survivability key) and Site B
// (`DocumentSearcher.composedSurvivors`, the Search gate; frozen) compose
// the same chain — absorbing-state floor → learned context term →
// calibrated posterior → under-redaction floor — from separate code. This
// suite is the sync enforcement between them:
//   1. over synthetic pages at the doctype-blind `.generic`, the Site-A
//      posterior equals the Site-B posterior to the bit. Site B never
//      reports its posterior, so it is recovered through
//      `composedSurvivors`'s own gate: a match survives a cutoff of p and
//      not a cutoff of p.nextUp exactly when its posterior is p.
//   2. over the distinct fire-feature vectors of the G8 Site-B run of
//      record (a bundled copy: feature values and raw scores, never text),
//      the Site-A tail reproduces the recorded `surfaced` flag at the
//      balanced preset; the doctype grid's spread is reported.
@Suite("Posterior chain parity (Site A ↔ Site B)")
struct PosteriorChainParityTests {

    // MARK: - The fire-vector fixture

    struct Fixture: Decodable {
        struct Row: Decodable {
            let family: String
            let features: [Double]
            let raw: Double
            let surfaced: Bool
            let count: Int
        }
        let feature_order: [String]
        let rows: [Row]
    }

    static func loadFixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(
            forResource: "posterior_chain_fire_vectors", withExtension: "json",
            subdirectory: "vectors"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    static func category(forWire wire: String) -> PIICategory? {
        PIICategory.allCases.first { PresetThresholdVector.wireName(for: $0) == wire }
    }

    static let doctypeGrid: [DoctypeClass] = [.generic, .court, .medical, .financial, .foia]

    // MARK: - Site B, read through its own gate

    /// Whether a single match survives `composedSurvivors` at `cutoff`.
    static func siteBSurvives(
        _ match: PIIDetector.PIIMatch, pageText: String, wire: String,
        cutoff: Double, scorer: ContextScorerWeights
    ) -> Bool {
        let vector = PresetThresholdVector(thresholdsByWireName: [wire: cutoff])
        let survivors = DocumentSearcher.composedSurvivors(
            [match], pageText: pageText, thresholdVector: vector,
            calibratedScorer: CalibratedScorer(), contextScorer: scorer,
            priors: PerCategoryPriors())
        return !survivors.isEmpty
    }

    /// The Site-B posterior to ~1e-16 by bisection on the cutoff (for the
    /// reported delta); the bit-equality assertion uses the two-probe form.
    static func siteBPosterior(
        _ match: PIIDetector.PIIMatch, pageText: String, wire: String,
        scorer: ContextScorerWeights
    ) -> Double {
        var low = 0.0, high = 1.0
        for _ in 0..<64 {
            let mid = (low + high) / 2
            if siteBSurvives(match, pageText: pageText, wire: wire, cutoff: mid, scorer: scorer) {
                low = mid
            } else {
                high = mid
            }
        }
        return low
    }

    // MARK: - Synthetic pages (five scored families; keyword, separator and label shapes)

    struct Page {
        let family: String
        let text: String
    }

    static let pages: [Page] = [
        Page(family: "account", text: "Account #: 123456789"),
        Page(family: "account", text: "Acct No. 1234-5678-9012 posted"),
        Page(family: "account", text: "Balance 123456789 carried forward"),
        Page(family: "account", text: "123456789\nAccount summary"),
        Page(family: "phone", text: "Phone: 555-123-4567"),
        Page(family: "phone", text: "Call 5551234567 today"),
        Page(family: "phone", text: "Case No: 5551234567 filed"),
        Page(family: "phone", text: "Tel 555.123.4567"),
        Page(family: "mrn", text: "MRN: 12345678"),
        Page(family: "mrn", text: "Patient chart\nMR-9988776"),
        Page(family: "mrn", text: "Record 99887766 reviewed"),
        Page(family: "ein", text: "EIN: 12-3456789"),
        Page(family: "ein", text: "Tax ID 123456789"),
        Page(family: "ein", text: "Employer 12-3456789 on file"),
        Page(family: "itin", text: "ITIN 912-34-5678"),
        Page(family: "itin", text: "912345678"),
        Page(family: "itin", text: "Taxpayer ID: 912-74-5678"),
    ]

    /// The page's match: its digit run (with separators), at the family's
    /// kind and the given raw score.
    static func match(in page: Page, raw: Double) throws -> PIIDetector.PIIMatch {
        let regex = try NSRegularExpression(pattern: "[0-9][0-9.\\-]*[0-9]")
        let nsText = page.text as NSString
        let range = try #require(
            regex.firstMatch(in: page.text, range: NSRange(location: 0, length: nsText.length))?.range)
        let category = try #require(Self.category(forWire: page.family))
        return PIIDetector.PIIMatch(
            text: nsText.substring(with: range), range: range,
            kind: category.piiKind, confidence: raw)
    }

    @Test("Site A equals Site B to the bit over synthetic pages at .generic")
    func siteAEqualsSiteB() throws {
        let fixture = try Self.loadFixture()
        let scorer = ContextScorerWeights.loadFromEngineBundle()
        let calibrated = CalibratedScorer()
        var rawsByFamily: [String: Set<Double>] = [:]
        for row in fixture.rows { rawsByFamily[row.family, default: []].insert(row.raw) }
        // The keyword-confirmed raws the under-redaction floor keys on.
        rawsByFamily["account", default: []].insert(0.75)
        rawsByFamily["phone", default: []].insert(0.80)

        var maxDelta = 0.0
        var compared = 0
        for page in Self.pages {
            let category = try #require(Self.category(forWire: page.family))
            for raw in (rawsByFamily[page.family] ?? []).sorted() {
                let match = try Self.match(in: page, raw: raw)
                let siteA = DetectionOrchestrator.posterior(
                    for: match, category: category, priors: PerCategoryPriors(),
                    effectiveDoctype: .generic, pageText: page.text,
                    contextScorer: scorer, calibratedScorer: calibrated)
                #expect(siteA.isFinite)
                let survivesAtP = Self.siteBSurvives(
                    match, pageText: page.text, wire: page.family, cutoff: siteA, scorer: scorer)
                let survivesAboveP = Self.siteBSurvives(
                    match, pageText: page.text, wire: page.family, cutoff: siteA.nextUp, scorer: scorer)
                #expect(survivesAtP && !survivesAboveP,
                        "Site B's posterior is not \(siteA) for \(page.family) raw \(raw): '\(page.text)'")
                let siteB = Self.siteBPosterior(match, pageText: page.text, wire: page.family, scorer: scorer)
                maxDelta = max(maxDelta, abs(siteA - siteB))
                compared += 1
            }
        }
        print("[posterior-parity] Site A vs Site B over \(compared) (page, raw) inputs: max |Δ| = \(maxDelta)")
        #expect(compared >= Self.pages.count)
    }

    @Test("The Site-A tail reproduces the run of record's surfaced flags over the fire vectors")
    func fireVectorsReproduceSurfaced() throws {
        let fixture = try Self.loadFixture()
        let scorer = ContextScorerWeights.loadFromEngineBundle()
        let calibrated = CalibratedScorer()
        let balanced = try #require(PresetThresholdBundle.loadFromEngineBundle().presets[.balanced])
        let doctypeColumns: [DoctypeClass: Int] = [
            .court: try #require(fixture.feature_order.firstIndex(of: "doctype_is_court")),
            .medical: try #require(fixture.feature_order.firstIndex(of: "doctype_is_medical")),
            .financial: try #require(fixture.feature_order.firstIndex(of: "doctype_is_financial")),
            .foia: try #require(fixture.feature_order.firstIndex(of: "doctype_is_foia")),
            .generic: try #require(fixture.feature_order.firstIndex(of: "doctype_is_generic")),
        ]

        var flips = 0
        var gridSpread = 0.0
        var fires = 0
        for row in fixture.rows {
            let category = try #require(Self.category(forWire: row.family))
            let match = PIIDetector.PIIMatch(
                text: "", range: NSRange(location: 0, length: 0),
                kind: category.piiKind, confidence: row.raw)
            let priorMean = max(PerCategoryPriors().mean(category), DetectionOrchestrator.absorbingStateFloor)

            // The recorded vectors were computed at .generic; the tail at
            // those features against the balanced gate is the recorded flag.
            let logit = scorer.learnedContextLogit(family: row.family, features: row.features)
            let posterior = DetectionOrchestrator.posterior(
                for: match, category: category, priorMean: priorMean,
                contextLogit: logit, calibratedScorer: calibrated)
            let surfaced = balanced.threshold(for: category).map { posterior >= $0 } ?? true
            if surfaced != row.surfaced { flips += 1 }
            fires += row.count

            // The doctype grid: the one-hot columns swapped, everything else held.
            for doctype in Self.doctypeGrid {
                var features = row.features
                for (column, index) in doctypeColumns { features[index] = column == doctype ? 1 : 0 }
                let gridLogit = scorer.learnedContextLogit(family: row.family, features: features)
                let gridPosterior = DetectionOrchestrator.posterior(
                    for: match, category: category, priorMean: priorMean,
                    contextLogit: gridLogit, calibratedScorer: calibrated)
                gridSpread = max(gridSpread, abs(gridPosterior - posterior))
            }
        }
        print("[posterior-parity] \(fixture.rows.count) distinct vectors (\(fires) fires): surfaced flips = \(flips); doctype-grid max |Δ| vs .generic = \(gridSpread)")
        #expect(flips == 0)
        #expect(fixture.rows.count > 0)
    }
}
