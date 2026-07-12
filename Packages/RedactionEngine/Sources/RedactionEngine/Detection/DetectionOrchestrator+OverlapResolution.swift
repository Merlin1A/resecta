import Foundation

// W10 — Cross-category overlap resolution.
//
// When two detectors fire on the same (or overlapping) text range — e.g.
// DEA `AB1234567` vs. Bates `AB1234567` — the resolver keeps one winner
// and records the losers per-category for `CoverageReport`. Pure static
// function; safe to call from a `@concurrent` context.

extension DetectionOrchestrator {

    /// The result of a single resolver pass: the surviving matches, a
    /// per-category tally of suppressed losers, and the individual loser
    /// matches with `suppressedByOverlap(winnerCategory:)` appended to
    /// their rationale. The exporter reads `suppressedMatches` to populate
    /// the `suppressedByOverlap` audit column for each loser.
    public struct OverlapResolution: Sendable, Equatable {
        public let surviving: [PIIDetector.PIIMatch]
        public let suppressedCountByCategory: [PIICategory: Int]
        public let suppressedMatches: [PIIDetector.PIIMatch]

        public init(
            surviving: [PIIDetector.PIIMatch],
            suppressedCountByCategory: [PIICategory: Int],
            suppressedMatches: [PIIDetector.PIIMatch] = []
        ) {
            self.surviving = surviving
            self.suppressedCountByCategory = suppressedCountByCategory
            self.suppressedMatches = suppressedMatches
        }

        public static func == (lhs: OverlapResolution, rhs: OverlapResolution) -> Bool {
            guard lhs.suppressedCountByCategory == rhs.suppressedCountByCategory,
                  lhs.surviving.count == rhs.surviving.count,
                  lhs.suppressedMatches.count == rhs.suppressedMatches.count
            else { return false }
            for (l, r) in zip(lhs.surviving, rhs.surviving) {
                guard l.text == r.text,
                      NSEqualRanges(l.range, r.range),
                      l.kind == r.kind,
                      l.confidence == r.confidence
                else { return false }
            }
            for (l, r) in zip(lhs.suppressedMatches, rhs.suppressedMatches) {
                guard l.text == r.text,
                      NSEqualRanges(l.range, r.range),
                      l.kind == r.kind,
                      l.confidence == r.confidence
                else { return false }
            }
            return true
        }
    }

    /// D05-F2 — gate-aware ranking key for overlap winner selection. Lets the
    /// caller rank survivors by the post-posterior, preset-gate decision
    /// (`meetsThreshold`) and the floored posterior, rather than by raw
    /// detector confidence — so a sibling that will clear ITS own preset cutoff
    /// is not suppressed by a raw-stronger sibling the W4 gate would then
    /// reject. The orchestrator builds the key with the SAME posterior+cutoff
    /// math the W4 gate applies (DetectionOrchestrator.swift), so resolver
    /// ranking and gating agree by construction.
    public struct SurvivabilityKey: Sendable, Equatable {
        public let meetsThreshold: Bool
        public let posterior: Double
        public init(meetsThreshold: Bool, posterior: Double) {
            self.meetsThreshold = meetsThreshold
            self.posterior = posterior
        }
    }

    /// Resolve overlapping PII matches. Within each maximally-connected
    /// group of overlapping ranges, the highest-confidence match wins;
    /// ties break by the kind's `priorityRank`. Losers in a `PIICategory`
    /// bucket increment `suppressedCountByCategory[category]`.
    ///
    /// `.other` matches have no `PIICategory` (see
    /// `SearchTypes.swift:70`); losing `.other` members are not counted.
    ///
    /// D05-F1 — the surviving match's range is widened to the COALESCED span of
    /// its overlap group, so a partially-overlapping loser's non-overlapping
    /// tail still maps to a redaction region (no-op when the group shares one
    /// range).
    ///
    /// - Parameter survivability: D05-F2 — optional gate-aware ranking. When
    ///   supplied, the winner within each group is the member with the best
    ///   `SurvivabilityKey` (clears its preset cutoff → higher floored posterior
    ///   → higher `priorityRank`), so a raw-weaker but better-surviving sibling
    ///   is not discarded before the W4 gate runs. `nil` → legacy
    ///   raw-confidence ordering (with the D04-F4 near-tie dead-band).
    public static func resolveOverlaps(
        _ matches: [PIIDetector.PIIMatch],
        survivability: (@Sendable (PIIDetector.PIIMatch) -> SurvivabilityKey)? = nil
    ) -> OverlapResolution {
        guard matches.count > 1 else {
            return OverlapResolution(
                surviving: matches,
                suppressedCountByCategory: [:]
            )
        }
        let sorted = matches.sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            return priorityRank(for: lhs.kind) > priorityRank(for: rhs.kind)
        }
        var surviving: [PIIDetector.PIIMatch] = []
        var suppressed: [PIICategory: Int] = [:]
        var suppressedMatches: [PIIDetector.PIIMatch] = []
        var i = 0
        while i < sorted.count {
            var group = [sorted[i]]
            var unionEnd = NSMaxRange(sorted[i].range)
            var j = i + 1
            while j < sorted.count && sorted[j].range.location < unionEnd {
                group.append(sorted[j])
                unionEnd = max(unionEnd, NSMaxRange(sorted[j].range))
                j += 1
            }
            if group.count == 1 {
                surviving.append(group[0])
            } else {
                // Pick the winner, then widen its range to the coalesced group
                // span. `max(by:)` retains the first element on a tie, and the
                // sort above orders the high-`priorityRank` member first.
                let winner: PIIDetector.PIIMatch
                if let survivability {
                    // D05-F2 — rank by the post-posterior, gate-aware key:
                    // prefer the member that will clear its own preset cutoff;
                    // then the higher floored posterior; then higher
                    // `priorityRank`. Supersedes raw-confidence ranking (and the
                    // D04-F4 dead-band) on the production path, where the
                    // orchestrator supplies the same posterior+cutoff math the
                    // W4 gate applies.
                    winner = group.max { lhs, rhs in
                        let l = survivability(lhs), r = survivability(rhs)
                        if l.meetsThreshold != r.meetsThreshold { return !l.meetsThreshold }
                        if l.posterior != r.posterior { return l.posterior < r.posterior }
                        return priorityRank(for: lhs.kind) < priorityRank(for: rhs.kind)
                    }!
                } else {
                    // D04-F4 — dead-band so structural `priorityRank` governs a
                    // near-tie (within epsilon), not only an exact tie, in the
                    // RAW-confidence fallback. resolveOverlaps arbitrates on RAW
                    // confidence BEFORE the posterior/preset layers
                    // (DetectionOrchestrator.swift:386), so a loosely-validated
                    // generic kind (account, rank 1) must not edge out a
                    // structurally-stronger overlapping kind on a hairline delta.
                    let confidenceEpsilon = 0.02
                    winner = group.max { lhs, rhs in
                        if abs(lhs.confidence - rhs.confidence) > confidenceEpsilon {
                            return lhs.confidence < rhs.confidence
                        }
                        return priorityRank(for: lhs.kind) < priorityRank(for: rhs.kind)
                    }!
                }
                // D05-F1 — size the survivor to the COALESCED group span so a
                // partially-overlapping loser's non-overlapping tail still maps
                // to a redaction region downstream (boundingRect unions every
                // word box intersecting the range). Geometry only — kind,
                // confidence, rationale, and text are unchanged, so the W4 gate,
                // the `.address` text-keyed spatial lookup, and the audit tally
                // are all unaffected. `unionEnd` is the group's coalesced
                // NSMaxRange computed above. Identical/contained ranges are the
                // no-op case (coalescedRange == winner.range → survivor is the
                // winner).
                let groupStart = group.map { $0.range.location }.min()!
                let coalescedRange = NSRange(location: groupStart, length: unionEnd - groupStart)
                let survivor = NSEqualRanges(coalescedRange, winner.range)
                    ? winner
                    : winner.withRange(coalescedRange)
                surviving.append(survivor)
                let winnerCategory = PIICategory(piiKind: winner.kind)
                for loser in group {
                    if NSEqualRanges(loser.range, winner.range),
                       loser.kind == winner.kind {
                        continue
                    }
                    if let category = PIICategory(piiKind: loser.kind) {
                        suppressed[category, default: 0] += 1
                    }
                    if let winnerCategory {
                        suppressedMatches.append(
                            annotatedLoser(loser, winnerCategory: winnerCategory)
                        )
                    }
                }
            }
            i = j
        }
        return OverlapResolution(
            surviving: surviving,
            suppressedCountByCategory: suppressed,
            suppressedMatches: suppressedMatches
        )
    }

    /// Append `.suppressedByOverlap(winnerCategory:loserCategory:)` to the
    /// loser's rationale (synthesizing a minimal rationale if it had none) so
    /// the audit exporter and diagnostics UI can surface why the match was
    /// dropped. QW-5 (SRCH-ACCT-PHONE) — the signal carries the loser's OWN
    /// category alongside the winner's, so downstream labels read
    /// "Account, suppressed via Phone overlap" instead of only the winner's
    /// category.
    private static func annotatedLoser(
        _ loser: PIIDetector.PIIMatch,
        winnerCategory: PIICategory
    ) -> PIIDetector.PIIMatch {
        let signal: MatchRationale.Signal = .suppressedByOverlap(
            winnerCategory: winnerCategory,
            loserCategory: PIICategory(piiKind: loser.kind)
        )
        let existing = loser.rationale
        let newSignals: [MatchRationale.Signal] = (existing?.signals ?? []) + [signal]
        let newRationale = MatchRationale(
            ruleID: existing?.ruleID ?? "",
            signals: newSignals,
            preThresholdScore: existing?.preThresholdScore ?? loser.confidence,
            finalScore: existing?.finalScore ?? loser.confidence,
            appliedThreshold: existing?.appliedThreshold
        )
        return loser.withRationale(newRationale)
    }

    /// Priority rank used as a tie-breaker when two overlapping matches
    /// have identical confidence. Structural / checksum-backed detectors
    /// rank highest; loosely-labeled detectors rank lowest. `.other`
    /// stays at 0 so labelled kinds always win over it.
    static func priorityRank(for kind: RedactionRegion.PIIKind) -> Int {
        switch kind {
        case .ssn:            return 16
        case .itin:           return 15
        case .ein:            return 14
        case .creditCard:     return 13
        case .dea:            return 12
        // Checksum+prefix-backed, like DEA.
        // The dea tie is intentional and unreachable: the surface forms
        // ([A-Z]{2}\d{7} vs 9 digits) can never occupy the same text range.
        // creditCard (13) outranks routingNumber because it carries BOTH a
        // Luhn checksum AND an issuer-prefix guard.
        case .routingNumber:  return 12
        case .npi:            return 11
        case .medicalRecord:  return 10
        // DRAW-2 — Vision-detected barcode has machine-decoded payload; rank
        // alongside structural detectors. Sits below medicalRecord (10) and
        // above licensePlate (8) so a barcode overlap claim is preferred
        // over the loosely-labeled rect-based detectors below.
        case .barcode:        return 9
        case .licensePlate:   return 8
        case .email:          return 7
        case .phone:          return 6
        case .name:           return 5
        case .dateOfBirth:    return 4
        case .address:        return 3
        case .passport:       return 2
        case .driversLicense: return 1
        case .account:        return 1
        // DRAW-3 — Heuristic-only kind; participates in overlap resolution
        // (a text PII hit overlapping a signature box should win) but ranks
        // below any structured match. Same low rank as .other.
        case .signatureCandidate: return 0
        case .other:          return 0
        }
    }
}
