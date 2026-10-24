import SwiftUI
import RedactionEngine

// One responsibility: the editor's redaction mode. The per-document
// override lives on the document's state (`DocumentState.documentOverride`),
// so a new document and Start Over reset it with the rest of the document;
// the editor's runs and the paused banner read and write it through this
// forwarder. Switch Mode (the … menu's picker) shows the mode a run would
// use (`PipelineMode.effective`) and is unavailable, with the reason, while
// Paranoid Mode forces Secure Rasterization.

extension DocumentEditorView {

    var documentOverride: PipelineMode? {
        get { documentState.documentOverride }
        nonmutating set { documentState.documentOverride = newValue }
    }

    /// The mode a run would use now.
    var effectivePipelineMode: PipelineMode {
        PipelineMode.effective(
            paranoid: settingsState.paranoidMode, override: documentOverride, setting: settingsState.pipelineMode)
    }

    /// Switch Mode changes the override only while editing, and never under
    /// Paranoid Mode, which decides the mode itself.
    static func switchModeAvailable(phaseKind: DocumentState.PhaseKind, paranoid: Bool) -> Bool {
        phaseKind == .editing && !paranoid
    }

    /// Why Switch Mode is unavailable under Paranoid Mode: the Settings
    /// sentence.
    static func switchModeHint(paranoid: Bool) -> String {
        paranoid ? SettingsView.paranoidForcesSecureLine : ""
    }

    // Pipeline mode picker (per-document override). Unavailable, it is a
    // disabled row showing the mode in force: a disabled nested menu is
    // drawn as available inside the toolbar's … menu.
    var pipelineModePicker: some View {
        Group {
            if Self.switchModeAvailable(
                phaseKind: documentState.phaseKind, paranoid: settingsState.paranoidMode) {
                Menu {
                    Picker("Redaction Mode", selection: Binding(
                        get: { effectivePipelineMode },
                        set: { documentOverride = $0 }
                    )) {
                        Label { Text("Secure Rasterization") } icon: { PipelineMode.secureRasterization.glyph }
                            .tag(PipelineMode.secureRasterization)
                        Label { Text("Searchable Redaction") } icon: { PipelineMode.searchableRedaction.glyph }
                            .tag(PipelineMode.searchableRedaction)
                    }
                } label: {
                    // Verb-object menu label (was the bare noun "Mode").
                    Label { Text("Switch Mode") } icon: { effectivePipelineMode.glyph }
                }
            } else {
                Button {} label: {
                    Label { Text("Switch Mode") } icon: { effectivePipelineMode.glyph }
                }
                .disabled(true)
            }
        }
        .accessibilityHint(Self.switchModeHint(paranoid: settingsState.paranoidMode))
        .accessibilityIdentifier("pipelineMode")
    }
}
