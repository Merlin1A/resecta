import Foundation
import Testing
import RedactionCore

@Suite struct GeometryPolicyTests {
    static let policy = GeometryPolicy.release

    static var everyKey: [PolicyKey] {
        RegionKind.allCases.flatMap { kind in
            LineReading.allCases.flatMap { reading in
                [false, true].map { PolicyKey(kind: kind, reading: reading, switchOn: $0) }
            }
        }
    }

    /// The reasons that hold for a key, read from the region's kind and its
    /// line apart from the table.
    static func reasonsHolding(_ key: PolicyKey) -> [WidenReason] {
        var reasons: [WidenReason] = []
        if key.kind == .drawnByHand || key.kind == .placedFromTextThenEdited { reasons.append(.byHand) }
        if key.kind == .placedFromPicture || key.reading == .scanOrPicture { reasons.append(.scanOrPicture) }
        if key.reading == .direction { reasons.append(.direction) }
        if key.reading == .noColumn { reasons.append(.noColumn) }
        return reasons
    }

    @Test func theTableHasOneRowForEveryKey() {
        let keys = Self.policy.rows.map(\.key)
        #expect(keys.count == Self.everyKey.count)
        #expect(Set(keys) == Set(Self.everyKey))
        #expect(Set(keys).count == keys.count, "no key has two rows")
        for key in Self.everyKey {
            #expect(Self.policy.rule(for: key, source: .switchPolicy) != nil, "\(key)")
        }
    }

    @Test func theReleaseTableHoldsNoRowThatHidesOrNarrows() {
        for row in Self.policy.rows {
            #expect(row.rule.exposure == .canShowLength, "\(row.key): \(row.rule.exposure)")
        }
        #expect(Self.policy.asPlaced.exposure == .canShowLength)
        let worst = Exposure.worst(of: Self.policy.rows.map(\.rule.exposure) + [Self.policy.asPlaced.exposure])
        #expect(worst == .canShowLength)
        #expect(Self.policy.rows.allSatisfy { $0.rule.exposure != .hidden && $0.rule.exposure != .narrowed })
    }

    @Test func theTableDecodes() throws {
        let data = try JSONEncoder().encode(Self.policy)
        #expect(try JSONDecoder().decode(GeometryPolicy.self, from: data) == Self.policy)
        let written = Data("""
            {"key":{"kind":"placedFromTextAnchored","reading":"noColumn","switchOn":true},
             "rule":{"paint":"lineMargin","exposure":"canShowLength","outcome":{"couldNotWiden":{"reason":"noColumn"}}}}
            """.utf8)
        let row = try JSONDecoder().decode(PolicyRow.self, from: written)
        #expect(row == PolicyRow(key: PolicyKey(kind: .placedFromTextAnchored, reading: .noColumn, switchOn: true),
                                 rule: PolicyRule(paint: .lineMargin, exposure: .canShowLength,
                                                  outcome: .couldNotWiden(reason: .noColumn))))
        #expect(Self.policy.rows.contains(row))
    }

    @Test func aRowWithNoExposureDoesNotDecode() {
        let written = Data("""
            {"key":{"kind":"drawnByHand","reading":"column","switchOn":false},
             "rule":{"paint":"asDrawn","outcome":{"notAsked":{}}}}
            """.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PolicyRow.self, from: written) }
    }

    @Test func aRowThatCannotWidenNamesTheFirstReasonThatHolds() {
        for key in Self.everyKey where key.switchOn {
            let rule = Self.policy.rule(for: key, source: .switchPolicy)
            if let reason = WidenReason.first(of: Self.reasonsHolding(key)) {
                #expect(rule?.outcome == .couldNotWiden(reason: reason), "\(key)")
            } else {
                #expect(rule?.outcome == .byPaint, "\(key): a column is read and the plan compares the paints")
                #expect(rule?.paint == .band, "\(key)")
            }
        }
    }

    @Test func withTheSwitchOffNoRowAsksIt() {
        for key in Self.everyKey where !key.switchOn {
            let off = Self.policy.rule(for: key, source: .switchPolicy)
            #expect(off?.outcome == .notAsked, "\(key)")
            var on = key
            on.switchOn = true
            let onRule = Self.policy.rule(for: on, source: .switchPolicy)
            if onRule?.outcome != .byPaint {
                #expect(onRule?.paint == off?.paint, "\(key): a box that cannot be widened is painted as with the switch off")
            }
        }
    }

    @Test func eachKindOfRegionIsPaintedByItsRule() {
        for key in Self.everyKey {
            let paint = Self.policy.rule(for: key, source: .switchPolicy)?.paint
            switch key.kind {
            case .drawnByHand, .placedFromTextThenEdited:
                #expect(paint == .asDrawn, "\(key)")
            case .placedFromPicture:
                #expect(paint == .placedPlusFixedMargin, "\(key)")
            case .placedFromTextAnchored:
                switch key.reading {
                case .column: #expect(paint == (key.switchOn ? .band : .lineMargin), "\(key)")
                case .noColumn: #expect(paint == .lineMargin, "\(key)")
                case .scanOrPicture, .direction: #expect(paint == .placedPlusFixedMargin, "\(key)")
                }
            }
        }
    }

    @Test func thePlanMadeFromTheRegionsAsPlacedPaintsEachAsPlaced() {
        let asPlaced = PolicyRule(paint: .asPlaced, exposure: .canShowLength, outcome: .notAsked)
        #expect(Self.policy.asPlaced == asPlaced)
        for key in Self.everyKey {
            #expect(Self.policy.rule(for: key, source: .asPlaced) == asPlaced, "\(key)")
        }
        #expect(!Self.policy.rows.contains { $0.rule.paint == .asPlaced }, "only the as-placed rule paints as placed")
    }

    @Test func theConstantsAreTheTablesValues() {
        let constants = Self.policy.provisional
        #expect(Self.policy.fixedMarginSixtyFourths == 96, "1.5 pt")
        #expect(constants.runGap == Ratio(1, 1))
        #expect(constants.bridgingLines == 2)
        #expect(constants.stopLineHeights == Ratio(1, 2))
        #expect(constants.levelToleranceDegrees == 1)
        #expect(constants.lowestQualityDPI == 150)
        #expect(constants.stopPixelsSixtyFourths == 246, "eight pixels at 150 dpi are 3.84 pt, 245.76 sixty-fourths")
    }

    @Test func rightToLeftLettersAreInTheTablesRanges() {
        let ranges = Self.policy.provisional.rightToLeftScalars
        func listed(_ value: UInt32) -> Bool { ranges.contains { $0.contains(Unicode.Scalar(value)!) } }
        for letter: UInt32 in [0x05D0, 0x0627, 0x0710, 0x07CA, 0x0800, 0xFB1D, 0xFB50, 0xFE70, 0xFEFC, 0x10900, 0x1E900] {
            #expect(listed(letter), "U+\(String(letter, radix: 16, uppercase: true))")
        }
        for other: UInt32 in [0x0041, 0x058F, 0x0900, 0xFB1C, 0xFE6F, 0xFEFF, 0x107FF, 0x11000, 0x1E7FF, 0x1F000] {
            #expect(!listed(other), "U+\(String(other, radix: 16, uppercase: true))")
        }
    }
}
