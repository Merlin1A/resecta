import UIKit

// The committed boxes' pass. The boxes are layers kept by `boxLayers`
// (`BoxLayerHost`), which asks the overlay for a pass in its own layout;
// the overlay itself draws no bitmap. The marks drawn after the boxes (the
// search layer, the snap guides and the shapes being drawn) are the top
// canvas's (`OverlayTopCanvas`).

extension RedactionOverlayView: BoxLayerSource {
    /// The committed boxes' layer descriptions, with `toDevice` the map from
    /// overlay points to the screen's device pixels. The plan this page is
    /// drawn from is kept with its settings first, and the boxes are made
    /// from it.
    func boxLayerPass(toDevice: CGAffineTransform) -> BoxLayerPass {
        coordinator?.noteDrawn(pageIndex: pageIndex, regions: regions)
        let plan = coordinator?.redactionState?.drawnPlans[pageIndex]
        let steps = committedSteps(in: bounds, plan: plan)
        let made = BoxLayers.specs(steps: steps, toDevice: toDevice, clip: pageRectOnCanvas.intersection(bounds))
        return BoxLayerPass(specs: made.specs, groups: made.groups, planBoxes: plan?.boxes ?? [])
    }

    /// A gesture's step: the top canvas, and the layers of the boxes it
    /// moves (with those whose plan box it changes).
    func redrawGesture() {
        topCanvas?.setNeedsDisplay()
        boxLayers.mark(.keys(Set(selectedIDs.map(\.uuidString))))
    }
}
