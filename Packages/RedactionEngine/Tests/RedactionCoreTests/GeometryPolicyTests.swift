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
                case .column: #expect(paint == (key.switchOn ? .band : .defaultBand), "\(key)")
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
        #expect(constants.levelSlope == Ratio(17_455, 1_000_000))
        #expect(constants.blockSpacing == BlockSpacing(excess: Ratio(1, 2), stepSixtyFourths: 32, fewestGaps: 4,
                                                       withoutOrdinaryGap: Ratio(1, 1)), "half a line height; 0.5 pt steps; four gaps")
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
    @Test func theLevelSlopeIsOneDegreesTangentRoundedDownToMillionths() {
        let slope = Self.policy.provisional.levelSlope
        let tangent = tan(Double.pi / 180)
        #expect(Double(slope.numerator) / Double(slope.denominator) <= tangent)
        #expect(Double(slope.numerator + 1) / Double(slope.denominator) > tangent)
    }

    @Test func onlyTheRangesLettersAreRightToLeftEvidence() {
        let constants = Self.policy.provisional
        func evidence(_ value: UInt32) -> Bool { constants.isRightToLeftLetter(Unicode.Scalar(value)!) }
        #expect(evidence(0x05D0), "Hebrew alef")
        #expect(evidence(0x0627), "Arabic alef")
        #expect(evidence(0xFEFB), "a presentation form of lam with alef")
        #expect(!evidence(0x0660), "Arabic-Indic digit zero: a digit, not a letter")
        #expect(!evidence(0x06F5), "extended Arabic-Indic digit five")
        #expect(!evidence(0x064B), "fathatan: a combining mark")
        #expect(!evidence(0x05B4), "Hebrew point hiriq: a combining mark")
        #expect(!evidence(0x060C), "Arabic comma: punctuation")
        #expect(!evidence(0x0041), "Latin capital A: outside the ranges")
    }

    /// The ranges were checked against the Unicode data files of the two
    /// versions the toolchains here carry (16.0 on the Linux build, 17.0 on
    /// the Mac): every letter of bidi class R or AL lies in a range, and
    /// every letter in a range is R or AL. The counts below are the letters
    /// (general category L*) in each range by those files; a toolchain with
    /// other data counts differently, and the ranges are then checked again
    /// against its files before this table is changed.
    @Test func theRangesLettersAreTheCountsTheUnicodeDataGives() {
        let ranges = Self.policy.provisional.rightToLeftScalars
        let counts = ranges.map { range in
            (range.first...range.last).reduce(0) { count, value in
                guard let scalar = Unicode.Scalar(value) else { return count }
                return Self.policy.provisional.isRightToLeftLetter(scalar) ? count + 1 : count
            }
        }
        let version = Unicode.Scalar(0x1FAEA)!.properties.age.map { "\($0.major).\($0.minor)" }
            ?? Unicode.Scalar(0x1CC00)!.properties.age.map { "\($0.major).\($0.minor)" } ?? "older"
        let byVersion: [String: [Int]] = ["17.0": [475, 635, 140, 954, 407], "16.0": [474, 635, 140, 925, 407]]
        let expected = byVersion[version]
        #expect(expected != nil, "Unicode \(version): check the ranges against this version's data files")
        if let expected { #expect(counts == expected, "Unicode \(version)") }
    }
}
