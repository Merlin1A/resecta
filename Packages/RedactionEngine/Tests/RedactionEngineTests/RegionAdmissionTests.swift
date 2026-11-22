import CoreGraphics
import Foundation
import Testing
@testable import RedactionEngine

// Admission, one rule in one place: a region's rectangle is cut to the page on
// all four sides, and the part on the page must be more than one thousandth of
// the page wide and high. A refused region is never painted and is listed from
// the run's record with its reason; none vanishes. Every reader of admission
// gives one answer for one input.

@Suite("Region admission: one rule, with its reasons")
struct RegionAdmissionTests {

    /// Each case: a rectangle as drawn (shares of the page, any edge may lie
    /// off it) and admission's answer (nil = admitted).
    enum Case: String, CaseIterable, CustomTestStringConvertible {
        case whollyOffTheRight
        case halfOffTheLeft
        case thin
        case noArea
        case normal
        case whollyOffTheLeft
        case whollyBelow

        var testDescription: String { rawValue }

        var rect: CGRect {
            switch self {
            case .whollyOffTheRight: CGRect(x: 1.2, y: 0.6, width: 0.3, height: 0.05)
            case .halfOffTheLeft: CGRect(x: -0.15, y: 0.4, width: 0.3, height: 0.05)
            case .thin: CGRect(x: 0.3, y: 0.3, width: 0.0009, height: 0.2)
            case .noArea: CGRect(x: 0.5, y: 0.5, width: 0, height: 0)
            case .normal: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
            case .whollyOffTheLeft: CGRect(x: -0.5, y: 0.2, width: 0.3, height: 0.2)
            case .whollyBelow: CGRect(x: 0.2, y: -0.5, width: 0.3, height: 0.2)
            }
        }

        var answer: RegionAdmission.Refusal? {
            switch self {
            case .whollyOffTheRight, .whollyOffTheLeft, .whollyBelow: .offThePage
            case .thin, .noArea: .tooThinToPaint
            case .halfOffTheLeft, .normal: nil
            }
        }
    }

    static func region(_ rect: CGRect) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual)
    }

    @Test("The table holds exactly seven cases")
    func caseCount() { #expect(Case.allCases.count == 7) }

    @Test("Each case: the predicate's answer, and the record's list of refused regions", arguments: Case.allCases)
    func each(_ c: Case) {
        #expect(RedactionRegion.admission(normalizedRect: c.rect) == c.answer, "\(c.rect)")
        #expect(RedactionRegion.isAdmitted(normalizedRect: c.rect) == (c.answer == nil))
        let drawn = RunRecord.DrawnRegion(id: UUID(), normalizedRect: c.rect)
        let refused = RunRecord.Page(pageIndex: 0, regions: [drawn]).refusedRegions
        #expect(refused.map(\.id) == (c.answer == nil ? [] : [drawn.id]))
        #expect(refused.map(\.reason) == (c.answer.map { [$0] } ?? []))
        if c == .halfOffTheLeft {
            // Admitted on its on-page half: the same box slid further left,
            // so that 0.0009 of it lies on the page, is too thin to paint.
            #expect(RedactionRegion.admission(normalizedRect: CGRect(x: -0.2991, y: 0.4, width: 0.3, height: 0.05))
                    == .tooThinToPaint)
            #expect(RedactionRegion.admission(normalizedRect: CGRect(x: -0.2985, y: 0.4, width: 0.3, height: 0.05))
                    == nil)
        }
    }

    @Test("Every engine reader of admission gives one answer for one input")
    func oneAnswerAtEverySite() throws {
        let regions = Case.allCases.map { Self.region($0.rect) }
        let admitted = zip(Case.allCases, regions).filter { $0.0.answer == nil }.map(\.1.id)
        let refused = zip(Case.allCases, regions).compactMap { c, r in c.answer.map { (r.id, $0) } }
        #expect(admitted.count == 2 && refused.count == 5)

        let drawn = regions.map { RunRecord.DrawnRegion(id: $0.id, normalizedRect: $0.normalizedRect) }
        let page = RunRecord.Page(pageIndex: 0, regions: drawn, cropBox: CGSize(width: 612, height: 792), rotation: 0, switchOn: false)
        let plan = try #require(page.plan)
        #expect(plan.boxes.map(\.regionIDs) == admitted.map { Set([$0]) }, "the record's plan")
        #expect(page.refusedRegions.map(\.id) == refused.map(\.0), "the record's refused list")
        #expect(page.refusedRegions.map(\.reason) == refused.map(\.1))
        #expect(VerificationEngine.layer2RegionSnapshot(regions).map(\.id) == admitted, "the Layer-2 region set")
        #expect(regions.filter { RedactionRegion.isAdmitted(normalizedRect: $0.normalizedRect) }.map(\.id) == admitted)
    }

    @Test("On a page, the admitted and the refused are together the record's regions, and none is both")
    func admittedAndRefusedPartitionTheRecord() throws {
        let regions = Case.allCases.map { RunRecord.DrawnRegion(id: UUID(), normalizedRect: $0.rect) }
        let page = RunRecord.Page(pageIndex: 0, regions: regions, cropBox: CGSize(width: 612, height: 792), rotation: 0, switchOn: false)
        let plan = try #require(page.plan)
        let admitted = Set(plan.boxes.flatMap(\.regionIDs))
        let refused = Set(page.refusedRegions.map(\.id))
        #expect(admitted.isDisjoint(with: refused))
        #expect(admitted.union(refused) == Set(regions.map(\.id)))
    }
}
