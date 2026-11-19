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
}
