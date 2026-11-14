import Foundation
import Testing
import RedactionCore

@Suite struct PaintedBoxTests {
    static let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    static let base = PaintedBox(
        regionIDs: [a], inner: PageRect64(minX: 640, minY: 6_400, maxX: 3_200, maxY: 7_168),
        paint: PageRect64(minX: 608, minY: 6_368, maxX: 3_264, maxY: 7_328),
        tight: PageRect64(minX: 640, minY: 6_400, maxX: 3_200, maxY: 7_168),
        limitAbove: 7_360, limitBelow: 6_336, exposure: .canShowLength, treatment: .notAsked,
        bandMade: false, inkEnlargedCovered: false, inkEnlargedToCap: false, asDrawn: false)

    @Test func theExposureOrderIsTotal() {
        let all = Exposure.allCases
        for x in all {
            for y in all {
                let held = [x < y, x == y, y < x].filter { $0 }.count
                #expect(held == 1, "\(x), \(y): exactly one of less, equal, greater")
                for z in all where x < y && y < z {
                    #expect(x < z, "\(x) < \(y) < \(z)")
                }
            }
        }
        #expect(all.sorted() == [.hidden, .narrowed, .canShowLength])
    }

    @Test func theWorstOfTwoExposuresIsTheOneThatCanShowMore() {
        for x in Exposure.allCases {
            for y in Exposure.allCases {
                let worst = x.worst(y)
                #expect(worst == y.worst(x), "\(x), \(y): the order of the two does not matter")
                #expect(worst >= x && worst >= y && (worst == x || worst == y), "\(x), \(y): \(worst)")
                #expect(Exposure.worst(of: [x, y]) == worst)
            }
        }
        #expect(Exposure.hidden.worst(.canShowLength) == .canShowLength)
        #expect(Exposure.narrowed.worst(.hidden) == .narrowed)
        #expect(Exposure.worst(of: []) == nil)
    }

    @Test func reasonsAreTriedInTheirFixedOrder() {
        #expect(WidenReason.allCases == [.byHand, .scanOrPicture, .direction, .noColumn])
        #expect(WidenReason.first(of: [.noColumn, .direction]) == .direction)
        #expect(WidenReason.first(of: [.noColumn, .scanOrPicture, .direction]) == .scanOrPicture)
        #expect(WidenReason.first(of: WidenReason.allCases.reversed()) == .byHand)
        #expect(WidenReason.first(of: []) == nil)
    }

    @Test func aBoxAlreadyAsWideAsItsLineIsInNeitherCount() {
        #expect(SwitchTreatment.alreadyAsWide.count == nil)
        #expect(SwitchTreatment.widened.count == .widened)
        for reason in WidenReason.allCases {
            #expect(SwitchTreatment.couldNotWiden(reason).count == .couldNotWiden(reason))
        }
        #expect(SwitchTreatment.notAsked.count == nil)
        #expect(SwitchTreatment.fellBack.count == nil)
    }

    @Test func boxesAlikeButForOneLimitLineAreNotEqual() {
        let box = Self.base
        var above = box
        above.limitAbove = 7_359
        #expect(above != box)
        var below = box
        below.limitBelow = 6_337
        #expect(below != box)
        var noneAbove = box
        noneAbove.limitAbove = nil
        #expect(noneAbove != box, "an absent limit is not equal to a present one")
        var noneBelow = box
        noneBelow.limitBelow = nil
        #expect(noneBelow != box, "an absent limit is not equal to a present one")
        #expect(box == Self.base)
    }

    @Test func boxesAlikeButForAnyOtherFieldAreNotEqual() {
        let box = Self.base
        var changed: [(String, PaintedBox)] = []
        var x = box; x.regionIDs = [Self.a, Self.b]; changed.append(("regions", x))
        x = box; x.inner.maxX += 1; changed.append(("inner", x))
        x = box; x.paint.minY -= 1; changed.append(("paint", x))
        x = box; x.tight.minX += 1; changed.append(("tight", x))
        x = box; x.exposure = .narrowed; changed.append(("exposure", x))
        x = box; x.treatment = .alreadyAsWide; changed.append(("treatment", x))
        x = box; x.treatment = .couldNotWiden(.noColumn); changed.append(("reason", x))
        x = box; x.bandMade = true; changed.append(("band", x))
        x = box; x.inkEnlargedCovered = true; changed.append(("ink covered", x))
        x = box; x.inkEnlargedToCap = true; changed.append(("ink to the cap", x))
        x = box; x.asDrawn = true; changed.append(("as drawn", x))
        for (field, other) in changed {
            #expect(other != box, "\(field)")
        }
        var otherReason = box
        otherReason.treatment = .couldNotWiden(.direction)
        var reason = box
        reason.treatment = .couldNotWiden(.noColumn)
        #expect(otherReason != reason)
    }

    @Test func plansMadeWithDifferentPageSidesAreNotEqual() {
        let plan = PaintPlan(widthSixtyFourths: 39_168, heightSixtyFourths: 50_688, boxes: [Self.base])
        #expect(plan == PaintPlan(widthSixtyFourths: 39_168, heightSixtyFourths: 50_688, boxes: [Self.base]))
        #expect(plan != PaintPlan(widthSixtyFourths: 39_169, heightSixtyFourths: 50_688, boxes: [Self.base]))
        #expect(plan != PaintPlan(widthSixtyFourths: 39_168, heightSixtyFourths: 50_687, boxes: [Self.base]))
        var other = Self.base
        other.limitBelow = nil
        #expect(plan != PaintPlan(widthSixtyFourths: 39_168, heightSixtyFourths: 50_688, boxes: [other]))
    }

    @Test func pointsBecomeWholeSixtyFourthsRoundedOutward() throws {
        let exact = try #require(PageRect64(outwardFromPoints: 10, minY: 100.5, maxX: 50.25, maxY: 112))
        #expect(exact == PageRect64(minX: 640, minY: 6_432, maxX: 3_216, maxY: 7_168))
        let hair = 1.0 / 4_096
        let inside = try #require(PageRect64(outwardFromPoints: 10 + hair, minY: 100.5 + hair, maxX: 50.25 - hair, maxY: 112 - hair))
        #expect(inside == PageRect64(minX: 640, minY: 6_432, maxX: 3_216, maxY: 7_168))
        let outside = try #require(PageRect64(outwardFromPoints: 10 - hair, minY: 100.5 - hair, maxX: 50.25 + hair, maxY: 112 + hair))
        #expect(outside == PageRect64(minX: 639, minY: 6_431, maxX: 3_217, maxY: 7_169))
        let offPage = try #require(PageRect64(outwardFromPoints: -2.01, minY: -0.5, maxX: -1.99, maxY: 0))
        #expect(offPage == PageRect64(minX: -129, minY: -32, maxX: -127, maxY: 0))
        #expect(PageRect64(outwardFromPoints: .nan, minY: 0, maxX: 1, maxY: 1) == nil)
        #expect(PageRect64(outwardFromPoints: 0, minY: 0, maxX: .infinity, maxY: 1) == nil)
        #expect(PageRect64(outwardFromPoints: 0, minY: 0, maxX: 0x1p30, maxY: 1) == nil)
    }

    @Test func aLimitLineIsRoundedTowardTheBox() {
        let hair = 1.0 / 4_096
        #expect(PaintedBox.limitAbove(points: 115) == 7_360)
        #expect(PaintedBox.limitAbove(points: 115 + hair) == 7_360)
        #expect(PaintedBox.limitAbove(points: 115 - hair) == 7_359)
        #expect(PaintedBox.limitBelow(points: 99) == 6_336)
        #expect(PaintedBox.limitBelow(points: 99 - hair) == 6_336)
        #expect(PaintedBox.limitBelow(points: 99 + hair) == 6_337)
        #expect(PaintedBox.limitAbove(points: -0.01) == -1)
        #expect(PaintedBox.limitBelow(points: -0.01) == 0)
        #expect(PaintedBox.limitAbove(points: .infinity) == nil)
        #expect(PaintedBox.limitBelow(points: .nan) == nil)
    }
}
