import Foundation
import RedactionEngine

// The geometry noted when a page's boxes are stored, for the run's box-place
// check (`RunRecord.Page.boxPlacesConfirmed`).

extension RedactionState {
    /// Notes the geometry of each page that holds a box and has none noted,
    /// and drops the note of each page that holds none. Runs on every write
    /// of `regions`, so a note is the geometry when the page's first box was
    /// stored.
    func noteGeometryAtStore() {
        for page in geometryAtStore.keys where regions[page]?.isEmpty ?? true {
            geometryAtStore[page] = nil
        }
        guard let read = pageGeometryReader else { return }
        for (page, list) in regions where !list.isEmpty && geometryAtStore[page] == nil {
            geometryAtStore[page] = read(page)
        }
    }

    /// The pages whose canvas did not pass the probe: those PDFKit handed a
    /// failing canvas, those whose live canvas fails it now, and those whose
    /// canvas last could not confirm its fills where the boxes were drawn.
    func canvasProbeFailuresAtRunEntry() -> Set<Int> {
        canvasProbeFailures.union(probeLiveCanvases?() ?? []).union(pagesWithUnconfirmedFill)
    }
}
