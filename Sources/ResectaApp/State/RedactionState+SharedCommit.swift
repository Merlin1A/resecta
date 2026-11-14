import Foundation
import RedactionEngine

extension RedactionState {
    // MARK: - Shared commit + the one undo implementation

    /// The single write-back transaction every apply origin commits
    /// through: one `regionVersion` bump, region + reverse-index
    /// insert, metadata + audit merge, verification/output
    /// invalidation, the run's deselection parts, and ONE two-leg undo
    /// registration. Undo removes the created regions with their metadata
    /// AND audit records in lockstep and gives back the deselection parts
    /// it found; redo re-inserts all three and the parts it set.
    func commitApply(
        createdRegions: [Int: [RedactionRegion]],
        createdMetadata: [UUID: RegionMetadata],
        createdAudit: [UUID: MatchAuditSnapshot],
        actionName: String,
        runDeselectionParts: [RunDeselectionPart],
        undoManager: UndoManager?
    ) {
        let partsBefore = pendingRunDeselectionParts
        pendingRunDeselectionParts = runDeselectionParts
        regionVersion += 1
        for (page, newRegions) in createdRegions {
            regions[page, default: []].append(contentsOf: newRegions)
            for region in newRegions { regionPageIndex[region.id] = page }
        }
        regionMetadata.merge(createdMetadata) { _, new in new }
        appliedMatchAudit.merge(createdAudit) { _, new in new }
        regionsModifiedSinceVerification = true
        clearOutput()

        let snapshot = createdRegions
        let metaSnapshot = createdMetadata
        let auditSnapshot = createdAudit
        registerUndo(undoManager, actionName) { target in
            for (page, newRegions) in snapshot {
                let idsToRemove = Set(newRegions.map(\.id))
                target.regions[page]?.removeAll { idsToRemove.contains($0.id) }
                for id in idsToRemove { target.regionPageIndex.removeValue(forKey: id) }
                target.selectedRegionIDs.subtract(idsToRemove)
            }
            for id in metaSnapshot.keys {
                target.regionMetadata.removeValue(forKey: id)
            }
            for id in auditSnapshot.keys {
                target.appliedMatchAudit.removeValue(forKey: id)
            }
            target.regionsModifiedSinceVerification = true
            target.clearOutput()
            target.pendingRunDeselectionParts = partsBefore
            // The undo leg is a region mutation like any other: bump
            // `regionVersion` so the overlay refresh gate and the search
            // sheet's applied-marker `.onChange` observe the removal.
            target.regionVersion += 1
            target.registerUndo(undoManager, actionName) { target2 in
                for (page, newRegions) in snapshot {
                    target2.regions[page, default: []].append(contentsOf: newRegions)
                    for region in newRegions { target2.regionPageIndex[region.id] = page }
                }
                target2.regionMetadata.merge(metaSnapshot) { _, new in new }
                target2.appliedMatchAudit.merge(auditSnapshot) { _, new in new }
                target2.regionsModifiedSinceVerification = true
                target2.clearOutput()
                target2.pendingRunDeselectionParts = runDeselectionParts
                // Redo re-inserts regions — a region mutation; the bump
                // keeps the canvas overlays refreshing. The sheet's
                // applied markers come back with the re-inserted audit
                // (`derivedSearchMarkers(for:)`), and a re-apply over the
                // regions no-ops as "already covered".
                target2.regionVersion += 1
            }
        }
    }
}
