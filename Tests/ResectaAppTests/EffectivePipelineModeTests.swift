import Testing
import Foundation
@testable import ResectaApp
import RedactionEngine

// Paranoid Mode forces Secure Rasterization: the run, the verify-only
// re-run and the editor's Switch Mode read one rule, so Switch Mode never
// offers a mode the run would not use, and it says why it is unavailable
// with the Settings sentence.

@Suite("Effective pipeline mode")
struct EffectivePipelineModeTests {

    @Test("Paranoid Mode forces Secure Rasterization over any override or setting")
    func paranoidForcesSecure() {
        for override in [nil, PipelineMode.secureRasterization, .searchableRedaction] {
            for setting in PipelineMode.allCases {
                #expect(PipelineMode.effective(paranoid: true, override: override, setting: setting)
                        == .secureRasterization)
            }
        }
    }

    @Test("Without Paranoid Mode the document's override wins, else the setting")
    func overrideThenSetting() {
        #expect(PipelineMode.effective(paranoid: false, override: .searchableRedaction, setting: .secureRasterization)
                == .searchableRedaction)
        #expect(PipelineMode.effective(paranoid: false, override: nil, setting: .searchableRedaction)
                == .searchableRedaction)
    }

    @MainActor
    @Test("Switch Mode is unavailable under Paranoid Mode and says why with the Settings sentence")
    func switchModeUnderParanoid() {
        #expect(SettingsView.paranoidForcesSecureLine == "Pipeline mode is forced to Secure Rasterization.")
        #expect(!DocumentEditorView.switchModeAvailable(phaseKind: .editing, paranoid: true))
        #expect(DocumentEditorView.switchModeAvailable(phaseKind: .editing, paranoid: false))
        #expect(!DocumentEditorView.switchModeAvailable(phaseKind: .verified, paranoid: false))
        #expect(DocumentEditorView.switchModeHint(paranoid: true) == SettingsView.paranoidForcesSecureLine)
        #expect(DocumentEditorView.switchModeHint(paranoid: false) == "")
    }
}
