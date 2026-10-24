import Testing
import Foundation
import CoreGraphics
import UIKit
import RedactionEngine
@testable import ResectaApp

// The selection under Differentiate Without Color. A selected region is
// blue and an unselected one red, green or orange; with the setting on,
// colour alone does not tell them apart, so every member of a
// multi-selection also carries a dashed outline 2 on-screen points wide
// (a single selection shows its handles). Nothing changes with the
// setting off. The overlay redraws when the setting changes.

@Suite("Selected cue")
@MainActor
struct SelectedCueTests {

    @Test("Every member of a multi-selection carries the dashed outline only while the setting is on")
    func cueOnlyUnderTheSetting() {
        let fingerScale: CGFloat = 1 / 0.64
        #expect(RedactionOverlayView.selectionCue(isSelected: true, selectionCount: 3, differentiateWithoutColor: false, fingerScale: fingerScale) == nil)
        let cue = RedactionOverlayView.selectionCue(isSelected: true, selectionCount: 3, differentiateWithoutColor: true, fingerScale: fingerScale)
        #expect(cue != nil)
        #expect(cue.map { !$0.dash.isEmpty } == true, "dashed")
        #expect(RedactionOverlayView.selectionCue(isSelected: false, selectionCount: 3, differentiateWithoutColor: true, fingerScale: fingerScale) == nil)
        #expect(RedactionOverlayView.selectionCue(isSelected: true, selectionCount: 1, differentiateWithoutColor: true, fingerScale: fingerScale) == nil,
                "a single selection shows its handles")
    }

    @Test("The outline is 2 on-screen points wide at the fit zoom and at 2x")
    func cueKeepsOneOnScreenWidth() throws {
        for viewScale: CGFloat in [0.64, 2.0] {
            let cue = try #require(RedactionOverlayView.selectionCue(
                isSelected: true, selectionCount: 2, differentiateWithoutColor: true, fingerScale: 1 / viewScale))
            #expect(abs(cue.lineWidth * viewScale - 2) < 0.01)
        }
    }

    @Test("The overlay redraws when Differentiate Without Color changes")
    func redrawsOnTheSettingChange() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let overlay = RedactionOverlayView(frame: window.bounds)
        window.addSubview(overlay)
        window.isHidden = false
        overlay.layer.displayIfNeeded()
        #expect(overlay.layer.needsDisplay() == false)
        NotificationCenter.default.post(name: UIAccessibility.differentiateWithoutColorDidChangeNotification, object: nil)
        #expect(overlay.layer.needsDisplay())
        withExtendedLifetime(window) {}
    }
}
