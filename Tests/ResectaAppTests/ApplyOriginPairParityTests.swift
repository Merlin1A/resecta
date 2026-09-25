import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// Characterisation pin for the three detection origins of
// `RedactionState.applyFindings` — the staged review, an entity group,
// a raw detection map. Every region they create carries a
// `RegionMetadata` + `MatchAuditSnapshot` pair; this suite pins each
// pair's field values against the construction the origins used before
// the pair was built in one place — `RegionMetadata(piiKind:confidence:
// matchedText:recognitionLevel:isAmbiguousSurname:)` over the detection
// plus `MatchAuditSnapshot(detection:pageIndex:regionID:appliedAt:)` —
// so routing the origins through one preparation step cannot move a
// field. The region's source and rect are pinned to `toRegion()` too.
//
// With `RESECTA_APPLY_DUMP=<file>` in the test process's environment
// (`TEST_RUNNER_RESECTA_APPLY_DUMP` on the xcodebuild command line) the
// suite also writes every pair as sorted-key JSON — region ids
// ordinalised, `appliedAt` omitted — for a byte comparison of the same
// fixtures across commits. Fixture ids are fixed so the dump is stable.

@Suite("Apply origin pair parity")
@MainActor
struct ApplyOriginPairParityTests {

    // MARK: - Fixtures (fixed ids; synthetic text)

    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    private static func detection(
        _ n: Int, page: Int, kind: DetectionResult.Kind, text: String?,
        confidence: Double, level: DetectionResult.RecognitionLevel = .accurate,
        ocrSkipped: Bool = false
    ) -> DetectionResult {
        DetectionResult(
            id: id(n),
            normalizedRect: CGRect(
                x: 0.05 * Double(n), y: 0.1 + 0.04 * Double(page),
                width: 0.2, height: 0.03),
            kind: kind,
            confidence: confidence,
            matchedText: text,
            recognitionLevel: level,
            provenance: ocrSkipped
                ? DetectionResult.Provenance(ocrSkipped: true, ocrSkipReason: .coverageHighEnough)
                : .ocrRan
        )
    }

    /// The staged review: six detections over two pages; four accepted
    /// (one deselected, one with no selection entry at all), one name
    /// flagged ambiguous, one face with no text, one text-layer origin.
    private static let staged: [Int: [DetectionResult]] = [
        0: [
            detection(1, page: 0, kind: .pii(.ssn), text: "123-45-6789", confidence: 0.95),
            detection(2, page: 0, kind: .pii(.email), text: "j.doe@example.com",
                      confidence: 0.8, level: .fast, ocrSkipped: true),
            detection(3, page: 0, kind: .pii(.phone), text: "555-0100", confidence: 0.7),
        ],
        1: [
            detection(4, page: 1, kind: .pii(.name), text: "Jane Doe", confidence: 0.66),
            detection(5, page: 1, kind: .face, text: nil, confidence: 0.9),
            detection(6, page: 1, kind: .pii(.ssn), text: "987-65-4321", confidence: 0.5),
        ],
    ]
    private static let stagedSelections: [UUID: Bool] = [
        id(1): true, id(2): true, id(3): false, id(4): true, id(5): true,
    ]
    private static let stagedAmbiguous: Set<UUID> = [id(4)]

    /// The entity group: two members pending on different pages, one
    /// member no longer pending, one non-member left in the review.
    private static let groupPending: [Int: [DetectionResult]] = [
        0: [
            detection(11, page: 0, kind: .pii(.name), text: "Jane Doe", confidence: 0.9),
            detection(13, page: 0, kind: .pii(.email), text: "j.doe@example.com", confidence: 0.75),
        ],
        2: [
            detection(12, page: 2, kind: .pii(.name), text: "JANE DOE",
                      confidence: 0.85, ocrSkipped: true),
        ],
    ]
    private static let group = CrossPageEntityGroup(
        id: id(19), category: .name, canonicalText: "jane doe",
        pages: [0, 2], detectionIDs: [id(11), id(12), id(14)])
    private static let groupAmbiguous: Set<UUID> = [id(12)]

    /// The raw detection map: three applied, one signature candidate
    /// routed to the review.
    private static let map: [Int: [DetectionResult]] = [
        0: [
            detection(21, page: 0, kind: .pii(.ssn), text: "123-45-6789", confidence: 0.92),
            detection(22, page: 0, kind: .pii(.signatureCandidate), text: nil, confidence: 0.4),
        ],
        3: [
            detection(23, page: 3, kind: .face, text: nil, confidence: 0.88),
            detection(24, page: 3, kind: .pii(.phone), text: "555-0199",
                      confidence: 0.71, level: .fast),
        ],
    ]
    private static let mapAmbiguous: Set<UUID> = [id(23)]

    // MARK: - The pin

    private struct Pair {
        let page: Int
        let detection: DetectionResult
        let region: RedactionRegion
        let metadata: RegionMetadata
        let audit: MatchAuditSnapshot
    }

    /// Every created region joined to its metadata, audit record and the
    /// detection that produced it (by the audit's `resultID`), in page
    /// order then fixture-id order.
    private func pairs(
        in state: RedactionState, from detections: [Int: [DetectionResult]]
    ) -> [Pair] {
        let byID = Dictionary(
            uniqueKeysWithValues: detections.flatMap { page, rows in
                rows.map { ($0.id, (page: page, detection: $0)) }
            })
        var out: [Pair] = []
        for (page, regions) in state.regions {
            for region in regions {
                guard let audit = state.appliedMatchAudit[region.id],
                      let metadata = state.regionMetadata[region.id],
                      let source = byID[audit.resultID]
                else {
                    Issue.record("region \(region.id) on page \(page) lacks its pair")
                    continue
                }
                out.append(Pair(page: page, detection: source.detection,
                                region: region, metadata: metadata, audit: audit))
            }
        }
        return out.sorted {
            $0.page != $1.page
                ? $0.page < $1.page
                : $0.detection.id.uuidString < $1.detection.id.uuidString
        }
    }

    private func pin(
        _ pairs: [Pair], ambiguous: Set<UUID>, expectedIDs: [Int],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(pairs.map(\.detection.id) == expectedIDs.map(Self.id),
                "the created set, in page then id order", sourceLocation: sourceLocation)
        let stamps = Set(pairs.map(\.audit.appliedAt))
        #expect(stamps.count <= 1, "one apply, one appliedAt", sourceLocation: sourceLocation)
        for pair in pairs {
            let d = pair.detection
            let oracleRegion = d.toRegion()
            #expect(pair.region.normalizedRect == oracleRegion.normalizedRect, sourceLocation: sourceLocation)
            #expect(pair.region.source == oracleRegion.source, sourceLocation: sourceLocation)
            #expect(pair.audit.pageIndex == pair.page, sourceLocation: sourceLocation)

            let oracleMetadata = RegionMetadata(
                piiKind: d.kind,
                confidence: d.confidence,
                matchedText: d.matchedText,
                recognitionLevel: d.recognitionLevel,
                isAmbiguousSurname: ambiguous.contains(d.id)
            )
            #expect(pair.metadata.piiKind == oracleMetadata.piiKind, sourceLocation: sourceLocation)
            #expect(pair.metadata.confidence == oracleMetadata.confidence, sourceLocation: sourceLocation)
            #expect(pair.metadata.matchedText == oracleMetadata.matchedText, sourceLocation: sourceLocation)
            #expect(pair.metadata.recognitionLevel == oracleMetadata.recognitionLevel, sourceLocation: sourceLocation)
            #expect(pair.metadata.isAmbiguousSurname == oracleMetadata.isAmbiguousSurname, sourceLocation: sourceLocation)
            #expect(pair.metadata.badgeLabel == oracleMetadata.badgeLabel, sourceLocation: sourceLocation)
            #expect(pair.metadata.accessibilityDescription == oracleMetadata.accessibilityDescription,
                    sourceLocation: sourceLocation)

            let oracleAudit = MatchAuditSnapshot(
                detection: d, pageIndex: pair.page,
                regionID: pair.region.id, appliedAt: pair.audit.appliedAt)
            #expect(pair.audit == oracleAudit, sourceLocation: sourceLocation)
        }
    }

    @Test("Staged review: every accepted detection's pair matches the per-detection construction")
    func stagedReviewPairs() async {
        let state = RedactionState()
        state.pendingTriage = Self.staged
        state.triageSelections = Self.stagedSelections
        state.ambiguousSurnameDetectionIDs = Self.stagedAmbiguous

        let outcome = await state.applyFindings(.stagedDetections, undoManager: nil)

        #expect(outcome?.applied == 4)
        #expect(outcome?.signatureCandidates == 0)
        #expect(state.pendingTriage == nil)
        let pairs = pairs(in: state, from: Self.staged)
        pin(pairs, ambiguous: Self.stagedAmbiguous, expectedIDs: [1, 2, 4, 5])
        Self.dump("staged", pairs: pairs, outcome: outcome, remaining: state.pendingTriage)
    }

    @Test("Entity group: every pending member's pair matches the per-detection construction")
    func entityGroupPairs() async {
        let state = RedactionState()
        state.pendingTriage = Self.groupPending
        state.ambiguousSurnameDetectionIDs = Self.groupAmbiguous

        let outcome = await state.applyFindings(.entityGroup(Self.group), undoManager: nil)

        #expect(outcome?.applied == 2)
        #expect(state.pendingTriage?.values.flatMap { $0 }.map(\.id) == [Self.id(13)])
        let pairs = pairs(in: state, from: Self.groupPending)
        pin(pairs, ambiguous: Self.groupAmbiguous, expectedIDs: [11, 12])
        Self.dump("entityGroup", pairs: pairs, outcome: outcome, remaining: state.pendingTriage)
    }

    @Test("Detection map: every applied detection's pair matches the per-detection construction")
    func detectionMapPairs() async {
        let state = RedactionState()
        state.ambiguousSurnameDetectionIDs = Self.mapAmbiguous

        let outcome = await state.applyFindings(.detectionResults(Self.map), undoManager: nil)

        #expect(outcome?.applied == 3)
        #expect(outcome?.signatureCandidates == 1)
        #expect(state.pendingTriage?.values.flatMap { $0 }.map(\.id) == [Self.id(22)])
        let pairs = pairs(in: state, from: Self.map)
        pin(pairs, ambiguous: Self.mapAmbiguous, expectedIDs: [21, 23, 24])
        Self.dump("detectionMap", pairs: pairs, outcome: outcome, remaining: state.pendingTriage)
    }

    // MARK: - The dump (opt-in; sorted keys; no dates; ordinal region ids)

    private static func dump(
        _ origin: String, pairs: [Pair], outcome: RedactionState.ApplyOutcome?,
        remaining: [Int: [DetectionResult]]?
    ) {
        guard let path = ProcessInfo.processInfo.environment["RESECTA_APPLY_DUMP"] else { return }
        let rows: [[String: Any]] = pairs.enumerated().map { ordinal, pair in
            [
                "ordinal": ordinal,
                "page": pair.page,
                "detectionID": pair.detection.id.uuidString,
                "region": [
                    "source": String(describing: pair.region.source),
                    "rect": [pair.region.normalizedRect.origin.x, pair.region.normalizedRect.origin.y,
                             pair.region.normalizedRect.width, pair.region.normalizedRect.height],
                ],
                "metadata": [
                    "piiKind": String(describing: pair.metadata.piiKind),
                    "confidence": pair.metadata.confidence,
                    "matchedText": pair.metadata.matchedText ?? NSNull(),
                    "recognitionLevel": String(describing: pair.metadata.recognitionLevel),
                    "isAmbiguousSurname": pair.metadata.isAmbiguousSurname,
                    "badgeLabel": pair.metadata.badgeLabel,
                    "accessibilityDescription": pair.metadata.accessibilityDescription,
                ],
                "audit": [
                    "origin": String(describing: pair.audit.origin),
                    "resultID": pair.audit.resultID.uuidString,
                    "regionIDMatchesRegion": pair.audit.regionID == pair.region.id,
                    "pageIndex": pair.audit.pageIndex,
                    "matchedText": pair.audit.matchedText ?? NSNull(),
                    "source": pair.audit.source.map { String(describing: $0) } ?? NSNull(),
                    "piiCategory": pair.audit.piiCategory?.rawValue ?? NSNull(),
                    "piiConfidence": pair.audit.piiConfidence ?? NSNull(),
                    "rationale": pair.audit.rationale.map { String(describing: $0) } ?? NSNull(),
                    "term": pair.audit.term ?? NSNull(),
                    "hasSearchRecord": pair.audit.searchRecord != nil,
                ],
            ]
        }
        let record: [String: Any] = [
            "origin": origin,
            "applied": outcome?.applied ?? -1,
            "skippedOverlaps": outcome?.skippedOverlaps ?? -1,
            "signatureCandidates": outcome?.signatureCandidates ?? -1,
            "appliedResultIDs": outcome.map { $0.appliedResultIDs.map(\.uuidString).sorted() } ?? [],
            "remainingPending": (remaining ?? [:]).sorted { $0.key < $1.key }.map { page, rows in
                ["page": page, "ids": rows.map(\.id.uuidString)]
            },
            "pairs": rows,
        ]
        // One file per origin beside the given path, so the three tests
        // never race on one write.
        let url = URL(fileURLWithPath: path).deletingPathExtension()
            .appendingPathExtension("\(origin).json")
        guard let data = try? JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        else {
            Issue.record("the \(origin) dump did not serialise")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch { // LegalPhrases:safe (Swift keyword)
            Issue.record("the \(origin) dump did not write: \(error)")
        }
    }
}
