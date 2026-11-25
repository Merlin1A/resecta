import CoreGraphics
import Foundation
import RedactionCore

extension RunRecord {
    /// Where a run's plan comes from. The one place it is set: no launch
    /// argument, environment value, default or stored value reaches it. A
    /// test that needs the switch's policy hands a plan in by hand.
    package static let planSource: PlanSource = .asPlaced

    /// The plan's source and the user's switch as the plan reads them: under
    /// "as placed" the switch is ignored; under the switch's policy it
    /// reaches the plan.
    package static func planChoice(source: PlanSource, switchOn: Bool) -> (source: PlanSource, switchOn: Bool) {
        switch source {
        case .asPlaced: (.asPlaced, false)
        case .switchPolicy: (.switchPolicy, switchOn)
        }
    }

    /// The plan's regions for a page's admitted regions, in their order: each
    /// with its share and kind, and, for a region still anchored to the text
    /// it was placed from, the characters its match selected in `text`, the
    /// page's string (`WordSelection.characters`: white space and offsets
    /// outside `text` are left out). Every other region selects nothing.
    package static func planRegions(_ regions: [DrawnRegion], text: String) -> [PlanRegion] {
        regions.map { region in
            let r = region.normalizedRect
            let selected: Set<Int> = if region.kind == .placedFromTextAnchored, let range = region.pageCharacters {
                WordSelection.characters([range], in: text).offsets
            } else {
                []
            }
            return PlanRegion(id: region.id,
                              share: PointRect(minX: Double(r.minX), minY: Double(r.minY),
                                               maxX: Double(r.maxX), maxY: Double(r.maxY)),
                              kind: region.kind, selected: selected)
        }
    }
}
