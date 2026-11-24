import SwiftUI
import RedactionEngine

// One responsibility: the editor's redaction mode. The per-document
// override lives on the document's state (`DocumentState.documentOverride`),
// so a new document and Start Over reset it with the rest of the document;
// the editor's runs and the paused banner read it through this forwarder.
// No control sets it: Secure Rasterization is the only mode, and the run's
// rule (`PipelineMode.effective`) gives Secure Rasterization for every input.

extension DocumentEditorView {

    var documentOverride: PipelineMode? {
        get { documentState.documentOverride }
        nonmutating set { documentState.documentOverride = newValue }
    }
}
