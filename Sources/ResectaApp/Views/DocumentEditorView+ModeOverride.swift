import SwiftUI
import RedactionEngine

// One responsibility: the per-document redaction mode override lives on
// the document's state (`DocumentState.documentOverride`), so a new
// document and Start Over reset it with the rest of the document. The
// editor's picker, its runs and the paused banner read and write it
// through this forwarder.

extension DocumentEditorView {

    var documentOverride: PipelineMode? {
        get { documentState.documentOverride }
        nonmutating set { documentState.documentOverride = newValue }
    }
}
