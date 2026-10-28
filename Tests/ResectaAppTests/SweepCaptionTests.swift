import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The Detection Sweep's row says what the sweep does not read, on every
// outcome: the engine's own sentence first, then the formats it does not
// know. A PASS that says only "Names and addresses are not swept." reads as
// if everything else was.

@Suite("The Detection Sweep row names what it does not read")
@MainActor
struct SweepCaptionTests {

    private static func sweep(_ status: VerificationStatus) -> LayerResult {
        LayerResult(name: "Detection Sweep", symbolName: "sparkle.magnifyingglass", status: status,
                    shortDescription: "", detailDescription: "", pageReferences: nil, durationSeconds: 0,
                    layer: .detectionSweep)
    }

    @Test("Passed, a note and needs review alike: the engine's sentence, then photos, signatures and unknown number formats",
          arguments: [VerificationStatus.pass, .info("5 possible items remain"), .attention("a")])
    func captionNamesTheLimits(status: VerificationStatus) throws {
        let caption = try #require(LayerResultRow.rowCaptionText(layer: Self.sweep(status)))
        #expect(caption.hasPrefix(DetectionSweep.gateSentence))
        #expect(caption.contains("Photos"))
        #expect(caption.contains("signatures"))
        #expect(caption.contains("numbers in formats it does not know"))
    }

    @Test("VoiceOver reads the same caption")
    func spokenLabelFollowsTheCaption() throws {
        let layer = Self.sweep(.pass)
        let model = VerificationRowModel(layer: layer, perPageModes: [])
        let caption = try #require(LayerResultRow.rowCaptionText(layer: layer))
        #expect(LayerResultRow.accessibilityLabel(model: model, layer: layer).contains(caption))
    }
}
