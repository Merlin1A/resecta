import Testing
import Foundation
@testable import RedactionEngine

// W10 — DetectionOrchestrator.resolveOverlaps: cross-category overlap
// resolution. Pure static function, deterministic, sort-stable.

@Suite("Overlap resolver (W10)")
struct DetectionOrchestratorOverlapTests {

    private func match(
        text: String = "AB1234567",
        location: Int,
        length: Int = 9,
        kind: RedactionRegion.PIIKind,
        confidence: Double
    ) -> PIIDetector.PIIMatch {
        PIIDetector.PIIMatch(
            text: text,
            range: NSRange(location: location, length: length),
            kind: kind,
            confidence: confidence
        )
    }

    @Test("Empty input returns empty result")
    func resolveOverlapsEmptyInputReturnsEmpty() {
        let result = DetectionOrchestrator.resolveOverlaps([])
        #expect(result.surviving.isEmpty)
        #expect(result.suppressedCountByCategory.isEmpty)
    }

    @Test("Single match passes through untouched")
    func resolveOverlapsSingleMatchPassesThrough() {
        let m = match(location: 0, kind: .ssn, confidence: 0.9)
        let result = DetectionOrchestrator.resolveOverlaps([m])
        #expect(result.surviving.count == 1)
        #expect(result.suppressedCountByCategory.isEmpty)
    }

    @Test("Non-overlapping matches all survive")
    func resolveOverlapsNonOverlappingMatchesAllSurvive() {
        let m1 = match(location: 0, length: 5, kind: .ssn, confidence: 0.9)
        let m2 = match(location: 10, length: 5, kind: .email, confidence: 0.8)
        let m3 = match(location: 20, length: 5, kind: .phone, confidence: 0.7)
        let result = DetectionOrchestrator.resolveOverlaps([m1, m2, m3])
        #expect(result.surviving.count == 3)
        #expect(result.suppressedCountByCategory.isEmpty)
    }

    @Test("Higher confidence wins the overlap")
    func resolveOverlapsKeepsHigherConfidence() {
        let dea = match(location: 0, kind: .dea, confidence: 0.92)
        let plate = match(location: 0, kind: .licensePlate, confidence: 0.60)
        let result = DetectionOrchestrator.resolveOverlaps([plate, dea])
        #expect(result.surviving.count == 1)
        #expect(result.surviving.first?.kind == .dea)
        #expect(result.suppressedCountByCategory[.licensePlate] == 1)
    }

    @Test("Ties break on priority rank")
    func resolveOverlapsTieBreaksByPriority() {
        let mrn = match(location: 0, length: 8, kind: .medicalRecord, confidence: 0.80)
        let plate = match(location: 0, length: 8, kind: .licensePlate, confidence: 0.80)
        let result = DetectionOrchestrator.resolveOverlaps([plate, mrn])
        #expect(result.surviving.first?.kind == .medicalRecord)
        #expect(result.suppressedCountByCategory[.licensePlate] == 1)
    }

    @Test("Populates suppressed counts by category")
    func resolveOverlapsPopulatesSuppressedCounts() {
        let ssn = match(location: 0, length: 11, kind: .ssn, confidence: 0.95)
        let phone = match(location: 0, length: 11, kind: .phone, confidence: 0.80)
        let plate = match(location: 0, length: 11, kind: .licensePlate, confidence: 0.75)
        let result = DetectionOrchestrator.resolveOverlaps([ssn, phone, plate])
        #expect(result.surviving.count == 1)
        #expect(result.surviving.first?.kind == .ssn)
        #expect(result.suppressedCountByCategory[.phone] == 1)
        #expect(result.suppressedCountByCategory[.licensePlate] == 1)
    }

    @Test("Losing .other matches do not increment any category")
    func resolveOverlapsOtherKindNotCounted() {
        let ssn = match(location: 0, kind: .ssn, confidence: 0.90)
        let other = match(location: 0, kind: .other, confidence: 0.50)
        let result = DetectionOrchestrator.resolveOverlaps([ssn, other])
        #expect(result.surviving.count == 1)
        #expect(result.surviving.first?.kind == .ssn)
        #expect(result.suppressedCountByCategory.isEmpty)
    }

    @Test("Result is deterministic under input shuffles")
    func resolveOverlapsDeterministicUnderShuffle() {
        let fixtures: [PIIDetector.PIIMatch] = [
            match(location: 0, length: 9, kind: .dea, confidence: 0.92),
            match(location: 0, length: 9, kind: .phone, confidence: 0.60),
            match(location: 20, length: 8, kind: .medicalRecord, confidence: 0.85),
            match(location: 20, length: 8, kind: .phone, confidence: 0.85),
            match(location: 40, length: 5, kind: .email, confidence: 0.90),
            match(location: 50, length: 11, kind: .ssn, confidence: 0.95),
            match(location: 50, length: 11, kind: .licensePlate, confidence: 0.70),
            // D05-F1 — a partial-overlap group ([70,80) vs [75,85)) so the
            // widened-survivor path is exercised under shuffle. The coalesced
            // span [70,85) is order-independent (min location, max NSMaxRange).
            match(location: 70, length: 10, kind: .address, confidence: 0.70),
            match(location: 75, length: 10, kind: .ssn, confidence: 0.95),
        ]
        let baseline = DetectionOrchestrator.resolveOverlaps(fixtures)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<100 {
            var shuffled = fixtures
            shuffled.shuffle(using: &rng)
            let result = DetectionOrchestrator.resolveOverlaps(shuffled)
            #expect(result == baseline)
        }
    }

    @Test("Partial overlap widens the survivor to the coalesced span (D05-F1)")
    func resolveOverlapsPartialOverlap() {
        // email spans [0,11); phone spans [5,16). They overlap on [5,11).
        // The email wins on raw confidence (0.85 vs 0.70); D05-F1 widens its
        // range to the coalesced group span [0,16) so the phone's
        // non-overlapping tail [11,16) still maps to a redaction region.
        let email = match(text: "foo@bar.com", location: 0, length: 11, kind: .email, confidence: 0.85)
        let phone = match(text: "555-867-5309", location: 5, length: 11, kind: .phone, confidence: 0.70)
        let result = DetectionOrchestrator.resolveOverlaps([email, phone])
        #expect(result.surviving.count == 1)
        #expect(result.surviving.first?.kind == .email)
        #expect(NSEqualRanges(result.surviving.first!.range, NSRange(location: 0, length: 16)))
        // withRange copied the range only — the survivor keeps the winner's text.
        #expect(result.surviving.first?.text == "foo@bar.com")
        #expect(result.suppressedCountByCategory[.phone] == 1)
    }

    // MARK: - W10 adversarial pairs + suppressedByOverlap rationale

    @Test("NPI vs License Plate: NPI wins on tied confidence (rank 11 > 8)")
    func npiVsLicensePlateNPIWins() {
        let npi = match(text: "1455395883", location: 0, length: 10, kind: .npi, confidence: 0.80)
        let plate = match(text: "1455395883", location: 0, length: 10, kind: .licensePlate, confidence: 0.80)
        let result = DetectionOrchestrator.resolveOverlaps([plate, npi])
        #expect(result.surviving.count == 1)
        #expect(result.surviving.first?.kind == .npi)
        #expect(result.suppressedCountByCategory[.licensePlate] == 1)
        #expect(result.suppressedMatches.count == 1)
        let loserSignal = result.suppressedMatches.first?.rationale?.signals.last
        #expect(loserSignal == .suppressedByOverlap(winnerCategory: .npi, loserCategory: .licensePlate))
    }

    @Test("MRN vs Account: MRN wins (rank 10 > 1)")
    func mrnVsAccountMRNWins() {
        let mrn = match(text: "QD793210", location: 0, length: 8, kind: .medicalRecord, confidence: 0.75)
        let account = match(text: "QD793210", location: 0, length: 8, kind: .account, confidence: 0.75)
        let result = DetectionOrchestrator.resolveOverlaps([account, mrn])
        #expect(result.surviving.count == 1)
        #expect(result.surviving.first?.kind == .medicalRecord)
        #expect(result.suppressedCountByCategory[.account] == 1)
        #expect(result.suppressedMatches.count == 1)
        let loserSignal = result.suppressedMatches.first?.rationale?.signals.last
        #expect(loserSignal == .suppressedByOverlap(winnerCategory: .medicalRecord, loserCategory: .account))
    }

    @Test("License plate vs EIN: EIN wins (rank 14 > 8)")
    func licensePlateVsEINEINWins() {
        let ein = match(text: "12-3456789", location: 0, length: 10, kind: .ein, confidence: 0.70)
        let plate = match(text: "12-3456789", location: 0, length: 10, kind: .licensePlate, confidence: 0.70)
        let result = DetectionOrchestrator.resolveOverlaps([plate, ein])
        #expect(result.surviving.count == 1)
        #expect(result.surviving.first?.kind == .ein)
        #expect(result.suppressedCountByCategory[.licensePlate] == 1)
        #expect(result.suppressedMatches.count == 1)
        let loserSignal = result.suppressedMatches.first?.rationale?.signals.last
        #expect(loserSignal == .suppressedByOverlap(winnerCategory: .ein, loserCategory: .licensePlate))
    }

    @Test("Suppressed loser preserves its pre-existing rationale signals")
    func suppressedLoserPreservesPriorSignals() {
        // Simulate a license-plate loser that already carried a regexPattern
        // signal from its detector; resolver appends .suppressedByOverlap on top.
        let existing = MatchRationale(
            ruleID: "licensePlate.labeled",
            signals: [.regexPattern(name: "licensePlate.labeled")],
            preThresholdScore: 0.30,
            finalScore: 0.80
        )
        let plate = PIIDetector.PIIMatch(
            text: "AB1234567",
            range: NSRange(location: 0, length: 9),
            kind: .licensePlate,
            confidence: 0.80,
            rationale: existing
        )
        let dea = match(text: "AB1234567", location: 0, length: 9, kind: .dea, confidence: 0.92)
        let result = DetectionOrchestrator.resolveOverlaps([plate, dea])
        let loser = result.suppressedMatches.first
        #expect(loser?.rationale?.signals.count == 2)
        #expect(loser?.rationale?.signals.first == .regexPattern(name: "licensePlate.labeled"))
        #expect(loser?.rationale?.signals.last == .suppressedByOverlap(winnerCategory: .dea, loserCategory: .licensePlate))
    }

    // MARK: - QW-5 (SRCH-ACCT-PHONE) suppressed-loser label

    @Test("Account loses to Phone: loser keeps its OWN category in counts and rationale")
    func accountLosesToPhoneLoserKeepsOwnCategory() {
        // The SRCH-ACCT-PHONE pair: an account-number candidate overlapping
        // a phone candidate. Phone wins (higher confidence); the suppressed
        // loser must be tallied and labeled as `account` — its own
        // category — with the winner carried separately in the signal.
        let phone = match(text: "555-867-5309", location: 0, length: 12, kind: .phone, confidence: 0.85)
        let account = match(text: "555-867-5309", location: 0, length: 12, kind: .account, confidence: 0.60)
        let result = DetectionOrchestrator.resolveOverlaps([account, phone])
        #expect(result.surviving.count == 1)
        #expect(result.surviving.first?.kind == .phone)
        // Count keyed by the LOSER's category, not the winner's.
        #expect(result.suppressedCountByCategory[.account] == 1)
        #expect(result.suppressedCountByCategory[.phone] == nil)
        // Rationale carries both: the loser's own category and the winner.
        let loserSignal = result.suppressedMatches.first?.rationale?.signals.last
        #expect(loserSignal == .suppressedByOverlap(winnerCategory: .phone, loserCategory: .account))
        // Audit summary renders the loser as itself, "via" the winner.
        let summary = MatchAuditExporter.rationaleSummary(
            result.suppressedMatches.first?.rationale
        )
        #expect(summary.contains("suppressedByOverlap(Account via Phone)"))
    }

    // MARK: - D05-F1 coalesced-survivor range

    @Test("Partial overlap widens survivor range; structured winner past loser (D05-F1)")
    func resolveOverlapsPartialOverlapWidensSurvivorRange() {
        // address [0,40) loses to ssn [30,41); the survivor widens to [0,41)
        // so the address head the ssn does not cover is still redacted.
        let address = match(text: "100 Main Street, Apt 4, Springfield",
                            location: 0, length: 40, kind: .address, confidence: 0.70)
        let ssn = match(text: "123-45-6789", location: 30, length: 11, kind: .ssn, confidence: 0.95)
        let r1 = DetectionOrchestrator.resolveOverlaps([address, ssn])
        #expect(r1.surviving.count == 1)
        #expect(r1.surviving.first?.kind == .ssn)
        #expect(NSEqualRanges(r1.surviving.first!.range, NSRange(location: 0, length: 41)))
        #expect(r1.surviving.first?.text == "123-45-6789")
        #expect(r1.suppressedCountByCategory[.address] == 1)

        // Symmetric: the address wins (higher raw) and a structured loser
        // extends past it; the survivor still coalesces to cover the tail.
        let addressWin = match(text: "742 Evergreen Terrace, Springfield USA",
                               location: 0, length: 50, kind: .address, confidence: 0.90)
        let ssnTail = match(text: "987-65-4321", location: 40, length: 15, kind: .ssn, confidence: 0.70)
        let r2 = DetectionOrchestrator.resolveOverlaps([addressWin, ssnTail])
        #expect(r2.surviving.count == 1)
        #expect(r2.surviving.first?.kind == .address)
        #expect(NSEqualRanges(r2.surviving.first!.range, NSRange(location: 0, length: 55)))
        #expect(r2.surviving.first?.text == "742 Evergreen Terrace, Springfield USA")
        #expect(r2.suppressedCountByCategory[.ssn] == 1)
    }

    // MARK: - D05-F2 gate-aware winner selection

    @Test("Gate-surviving sibling wins over a raw-stronger gate-failing one (D05-F2)")
    func resolveOverlapsPrefersGateSurvivor() {
        // phone has the higher RAW confidence (0.80 > 0.70); without the
        // gate-aware key it would win. The stub marks phone as failing its
        // gate and account as passing → account survives.
        let phone = match(location: 0, length: 11, kind: .phone, confidence: 0.80)
        let account = match(location: 0, length: 11, kind: .account, confidence: 0.70)

        let failPhone: @Sendable (PIIDetector.PIIMatch) -> DetectionOrchestrator.SurvivabilityKey = { m in
            m.kind == .phone
                ? .init(meetsThreshold: false, posterior: 0.50)
                : .init(meetsThreshold: true, posterior: 0.65)
        }
        let r1 = DetectionOrchestrator.resolveOverlaps([phone, account], survivability: failPhone)
        #expect(r1.surviving.first?.kind == .account)
        #expect(r1.suppressedCountByCategory[.phone] == 1)

        // Both pass the gate → the higher floored posterior wins (account 0.65
        // > phone 0.50, again despite phone's higher raw 0.80).
        let bothPass: @Sendable (PIIDetector.PIIMatch) -> DetectionOrchestrator.SurvivabilityKey = { m in
            m.kind == .phone
                ? .init(meetsThreshold: true, posterior: 0.50)
                : .init(meetsThreshold: true, posterior: 0.65)
        }
        let r2 = DetectionOrchestrator.resolveOverlaps([phone, account], survivability: bothPass)
        #expect(r2.surviving.first?.kind == .account)

        // Identical keys → the priorityRank tie-break decides (phone rank 6 >
        // account rank 1).
        let tie: @Sendable (PIIDetector.PIIMatch) -> DetectionOrchestrator.SurvivabilityKey = { _ in
            .init(meetsThreshold: true, posterior: 0.60)
        }
        let r3 = DetectionOrchestrator.resolveOverlaps([phone, account], survivability: tie)
        #expect(r3.surviving.first?.kind == .phone)
    }

    @Test("nil survivability equals the no-closure resolver (D05-F2)")
    func resolveOverlapsNilSurvivabilityMatchesLegacy() {
        let group: [PIIDetector.PIIMatch] = [
            match(location: 0, length: 11, kind: .ssn, confidence: 0.95),
            match(location: 0, length: 11, kind: .phone, confidence: 0.80),
            match(location: 5, length: 11, kind: .account, confidence: 0.58),
        ]
        let noClosure = DetectionOrchestrator.resolveOverlaps(group)
        let nilClosure = DetectionOrchestrator.resolveOverlaps(group, survivability: nil)
        #expect(noClosure == nilClosure)
    }

    @Test("SurvivabilityKey is Equatable; meetsThreshold dominates posterior (D05-F2)")
    func survivabilityKeyComparatorSemantics() {
        #expect(DetectionOrchestrator.SurvivabilityKey(meetsThreshold: true, posterior: 0.6)
                == DetectionOrchestrator.SurvivabilityKey(meetsThreshold: true, posterior: 0.6))
        #expect(DetectionOrchestrator.SurvivabilityKey(meetsThreshold: true, posterior: 0.6)
                != DetectionOrchestrator.SurvivabilityKey(meetsThreshold: false, posterior: 0.6))
        // A gate-FAILING member with a higher posterior still loses to a
        // gate-PASSING member with a lower posterior.
        let a = match(location: 0, length: 9, kind: .phone, confidence: 0.90)
        let b = match(location: 0, length: 9, kind: .account, confidence: 0.50)
        let surv: @Sendable (PIIDetector.PIIMatch) -> DetectionOrchestrator.SurvivabilityKey = { m in
            m.kind == .phone
                ? .init(meetsThreshold: false, posterior: 0.95)
                : .init(meetsThreshold: true, posterior: 0.40)
        }
        let result = DetectionOrchestrator.resolveOverlaps([a, b], survivability: surv)
        #expect(result.surviving.first?.kind == .account)
    }

    @Test("Survivability-ranked result is deterministic under input shuffles (D05-F2)")
    func resolveOverlapsDeterministicUnderShuffleWithSurvivability() {
        let fixtures: [PIIDetector.PIIMatch] = [
            match(location: 0, length: 11, kind: .phone, confidence: 0.80),
            match(location: 0, length: 11, kind: .account, confidence: 0.70),
            match(location: 0, length: 11, kind: .ssn, confidence: 0.60),
            match(location: 30, length: 8, kind: .medicalRecord, confidence: 0.55),
            match(location: 30, length: 8, kind: .account, confidence: 0.95),
        ]
        let surv: @Sendable (PIIDetector.PIIMatch) -> DetectionOrchestrator.SurvivabilityKey = { m in
            switch m.kind {
            case .ssn:           return .init(meetsThreshold: true, posterior: 0.90)
            case .phone:         return .init(meetsThreshold: false, posterior: 0.85)
            case .account:       return .init(meetsThreshold: true, posterior: 0.50)
            case .medicalRecord: return .init(meetsThreshold: true, posterior: 0.70)
            default:             return .init(meetsThreshold: true, posterior: m.confidence)
            }
        }
        let baseline = DetectionOrchestrator.resolveOverlaps(fixtures, survivability: surv)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<100 {
            var shuffled = fixtures
            shuffled.shuffle(using: &rng)
            let result = DetectionOrchestrator.resolveOverlaps(shuffled, survivability: surv)
            #expect(result == baseline)
        }
    }

    // MARK: - D04-F4 account generic-kind demotion (boostedConfidence 0.58)

    @Test("Account (0.58) does not suppress an overlapping address (0.70)")
    func test_accountDoesNotSuppressOverlappingAddress() {
        let address = match(location: 0, length: 11, kind: .address, confidence: 0.70)
        let account = match(location: 0, length: 11, kind: .account, confidence: 0.58)
        let result = DetectionOrchestrator.resolveOverlaps([address, account])
        #expect(result.surviving.count == 1)
        #expect(result.surviving.first?.kind == .address)
        #expect(result.suppressedCountByCategory[.account] == 1)
    }

    @Test("Account (0.58) does not suppress an overlapping phone (0.60)")
    func test_accountDoesNotSuppressOverlappingPhone() {
        let phone = match(location: 0, length: 11, kind: .phone, confidence: 0.60)
        let account = match(location: 0, length: 11, kind: .account, confidence: 0.58)
        let result = DetectionOrchestrator.resolveOverlaps([phone, account])
        #expect(result.surviving.count == 1)
        #expect(result.surviving.first?.kind == .phone)
        #expect(result.suppressedCountByCategory[.account] == 1)
    }

    @Test("A sole account hit (no overlap rival) still survives")
    func test_soleAccountStillSurvives() {
        let account = match(location: 0, length: 11, kind: .account, confidence: 0.58)
        let result = DetectionOrchestrator.resolveOverlaps([account])
        #expect(result.surviving.count == 1)
        #expect(result.surviving.first?.kind == .account)
        #expect(result.suppressedCountByCategory.isEmpty)
    }

    @Test("Account still wins over a truly-unstructured .other")
    func test_accountStillWinsOverPlainOther() {
        // .other is rank 0 with no PIICategory; account (rank 1) must still beat
        // it on a tie so a labelled generic kind is preferred over an unlabelled hit.
        let account = match(location: 0, length: 11, kind: .account, confidence: 0.58)
        let other = match(location: 0, length: 11, kind: .other, confidence: 0.58)
        let result = DetectionOrchestrator.resolveOverlaps([account, other])
        #expect(result.surviving.count == 1)
        #expect(result.surviving.first?.kind == .account)
        // .other carries no PIICategory, so the suppressed loser is not counted.
        #expect(result.suppressedCountByCategory.isEmpty)
    }

    @Test("Near-tie within epsilon favors structural rank, not raw confidence (D04-F4 Fix B)")
    func test_nearTieFavorsStructuralRank() {
        // account has the HIGHER raw (0.59) but the LOWER rank (1); address is
        // 0.58 / rank 3. The 0.02 dead-band makes structural rank decide, so
        // address wins despite account's higher raw — the discriminating case
        // the legacy exact-tie comparator would have lost to account.
        let account = match(location: 0, length: 11, kind: .account, confidence: 0.59)
        let address = match(location: 0, length: 11, kind: .address, confidence: 0.58)
        let result = DetectionOrchestrator.resolveOverlaps([account, address])
        #expect(result.surviving.count == 1)
        #expect(result.surviving.first?.kind == .address)
        #expect(result.suppressedCountByCategory[.account] == 1)
    }

    @Test("Exact tie still resolves by priority rank")
    func test_exactTieUnchanged() {
        let address = match(location: 0, length: 11, kind: .address, confidence: 0.70)
        let account = match(location: 0, length: 11, kind: .account, confidence: 0.70)
        let result = DetectionOrchestrator.resolveOverlaps([account, address])
        #expect(result.surviving.first?.kind == .address)
        #expect(result.suppressedCountByCategory[.account] == 1)
    }
}
