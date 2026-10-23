import Foundation
import RedactionEngine

// The undoable region mutations and the one undo helper they register
// through, moved out of `RedactionState.swift` along its
// `// MARK: - Region Mutations with Undo` and `// MARK: - Undo Helper`
// seams. The state they write stays on the class (an extension adds no
// storage); `bumpRegionVersion()` and `markRegionsModified()` are the
// one-way writes to its `private(set)` members.

extension RedactionState {

    // MARK: - Region Mutations with Undo

    func addRegion(_ region: RedactionRegion, page: Int, undoManager: UndoManager?) {
        bumpRegionVersion()
        regions[page, default: []].append(region)
        regionPageIndex[region.id] = page
        markRegionsModified()
        let regionID = region.id
        registerUndo(undoManager, "Add Redaction") { target in
            target.removeRegion(regionID, page: page, undoManager: undoManager)
        }
        // Post-add hook for the manual-draw nearby-PII
        // nudge. Only fires for `.manual` source regions — the search-
        // apply path that creates `.searchMatch` regions is itself the
        // origin of nudge candidates, so we deliberately skip it to
        // avoid recursive toast spam. The predicate handles all other
        // filtering (proximity, applied-IDs, category, suppression).
        if case .manual = region.source,
           let search = activeSearch,
           !manualDrawNudgeSuppressedForSession {
            let resultsSnapshot = MainActor.assumeIsolated { search.results }
            let appliedSnapshot = MainActor.assumeIsolated { search.appliedResultIDs }
            if let match = RedactionState.nearbyUnappliedPIIMatch(
                addedRegion: region,
                page: page,
                results: resultsSnapshot,
                appliedIDs: appliedSnapshot,
                suppressed: manualDrawNudgeSuppressedForSession,
                proximityNormalized: RedactionState.manualDrawNudgeProximityNormalized,
                coveringRects: regions[page]?.map(\.normalizedRect) ?? []
            ) {
                pendingManualDrawNudge = match
            }
        }
    }

    func removeRegion(_ id: UUID, page: Int, undoManager: UndoManager?) {
        guard var pageRegions = regions[page],
              let index = pageRegions.firstIndex(where: { $0.id == id }) else { return }
        bumpRegionVersion()
        selectedRegionIDs.remove(id)
        let removed = pageRegions.remove(at: index)
        regions[page] = pageRegions
        regionPageIndex.removeValue(forKey: id)
        let removedMetadata = regionMetadata.removeValue(forKey: id) // Capture metadata
        markRegionsModified()
        registerUndo(undoManager, "Delete Redaction") { target in
            target.addRegion(removed, page: page, undoManager: undoManager)
            if let removedMetadata { // Restore metadata on undo
                target.regionMetadata[removed.id] = removedMetadata
            }
        }
    }

    /// Resize a region. Like the two moves below, it is the one judge of a
    /// no-op: a rect equal to the stored one (a tap that ends a "drag"
    /// where it began, a nudge held at the page edge) bumps nothing,
    /// records no step and keeps the output. Returns whether the stored
    /// rect changed.
    @discardableResult
    func resizeRegion(
        _ id: UUID, page: Int,
        newRect: CGRect, undoManager: UndoManager?
    ) -> Bool {
        guard var pageRegions = regions[page],
              let index = pageRegions.firstIndex(where: { $0.id == id }),
              pageRegions[index].normalizedRect != newRect else { return false }
        bumpRegionVersion()
        let oldRect = pageRegions[index].normalizedRect
        pageRegions[index].normalizedRect = newRect
        regions[page] = pageRegions
        markRegionsModified()
        registerUndo(undoManager, "Resize Redaction") { target in
            target.resizeRegion(id, page: page, newRect: oldRect, undoManager: undoManager)
        }
        return true
    }

    // Move region to new position. Follows resizeRegion undo pattern.
    @discardableResult
    func moveRegion(
        _ id: UUID, page: Int,
        newRect: CGRect, undoManager: UndoManager?
    ) -> Bool {
        guard var pageRegions = regions[page],
              let index = pageRegions.firstIndex(where: { $0.id == id }),
              pageRegions[index].normalizedRect != newRect else { return false }
        bumpRegionVersion()
        let oldRect = pageRegions[index].normalizedRect
        pageRegions[index].normalizedRect = newRect
        regions[page] = pageRegions
        markRegionsModified()
        registerUndo(undoManager, "Move Redaction") { target in
            target.moveRegion(id, page: page, newRect: oldRect, undoManager: undoManager)
        }
        return true
    }

    /// Batch move multiple regions on the same page. Single undo action
    /// over the regions whose rect changed; none changed is a no-op.
    @discardableResult
    func moveRegions(_ moves: [(id: UUID, newRect: CGRect)], page: Int, undoManager: UndoManager?) -> Bool {
        guard var pageRegions = regions[page] else { return false }
        var mutableOldRects: [(id: UUID, oldRect: CGRect)] = []
        for move in moves {
            guard let index = pageRegions.firstIndex(where: { $0.id == move.id }),
                  pageRegions[index].normalizedRect != move.newRect else { continue }
            mutableOldRects.append((move.id, pageRegions[index].normalizedRect))
            pageRegions[index].normalizedRect = move.newRect
        }
        guard !mutableOldRects.isEmpty else { return false }
        bumpRegionVersion()
        regions[page] = pageRegions
        markRegionsModified()
        let snapshot = mutableOldRects
        registerUndo(undoManager, "Move Redactions") { target in
            let restoreMoves = snapshot.map { (id: $0.id, newRect: $0.oldRect) }
            target.moveRegions(restoreMoves, page: page, undoManager: undoManager)
        }
        return true
    }

    /// Batch remove multiple regions from a single page. Single undo action.
    func removeRegions(_ ids: Set<UUID>, page: Int, undoManager: UndoManager?) {
        bumpRegionVersion()
        guard var pageRegions = regions[page] else { return }
        var mutableRemoved: [(region: RedactionRegion, metadata: RegionMetadata?)] = []
        for id in ids {
            guard let index = pageRegions.firstIndex(where: { $0.id == id }) else { continue }
            let region = pageRegions.remove(at: index)
            let metadata = regionMetadata.removeValue(forKey: id)
            mutableRemoved.append((region, metadata))
        }
        regions[page] = pageRegions
        for id in ids { regionPageIndex.removeValue(forKey: id) }
        markRegionsModified()
        selectedRegionIDs.subtract(ids)
        let snapshot = mutableRemoved
        registerUndo(undoManager, "Delete Redactions") { target in
            for item in snapshot {
                target.regions[page, default: []].append(item.region)
                target.regionPageIndex[item.region.id] = page
                if let meta = item.metadata {
                    target.regionMetadata[item.region.id] = meta
                }
            }
            target.markRegionsModified()
            // Undo re-inserts the deleted regions — bump so the overlay
            // refresh gate observes it (the redo leg recurses into
            // `removeRegions`, which bumps at entry).
            target.bumpRegionVersion()
            target.registerUndo(undoManager, "Delete Redactions") { target2 in
                target2.removeRegions(ids, page: page, undoManager: undoManager)
            }
        }
    }

    /// Delete all selected regions, grouped by page for batch undo.
    /// Returns affected page indices so callers can refresh overlays.
    @discardableResult
    func deleteSelected(undoManager: UndoManager?) -> Set<Int> {
        let ids = selectedRegionIDs
        guard !ids.isEmpty else { return [] }
        var affectedPages: Set<Int> = []
        var byPage: [Int: Set<UUID>] = [:]
        for id in ids {
            if let page = pageIndex(for: id) {
                byPage[page, default: []].insert(id)
                affectedPages.insert(page)
            }
        }
        for (page, pageIDs) in byPage {
            if pageIDs.count == 1, let id = pageIDs.first {
                removeRegion(id, page: page, undoManager: undoManager)
            } else {
                removeRegions(pageIDs, page: page, undoManager: undoManager)
            }
        }
        selectedRegionIDs = []
        return affectedPages
    }

    /// Duplicate a region with a small offset. The copy is manual-sourced.
    /// Routes through `addRegion` for the actual mutation but
    /// overrides the inner action name so the iOS long-press Undo menu
    /// reads "Duplicate Redaction" rather than the generic "Add Redaction".
    func duplicateRegion(_ id: UUID, page: Int, undoManager: UndoManager?) {
        bumpRegionVersion()
        guard let pageRegions = regions[page],
              let region = pageRegions.first(where: { $0.id == id }) else { return }
        let newRect = RedactionState.duplicateOffsetClamp(
            source: region.normalizedRect
        )
        let copy = RedactionRegion(id: UUID(), normalizedRect: newRect, source: .manual)
        addRegion(copy, page: page, undoManager: undoManager)
        // Override the inner addRegion's "Add Redaction" name. UndoManager
        // setActionName is last-write-wins on the current registration.
        undoManager?.setActionName("Duplicate Redaction")
    }

    /// 0.02-offset clamp for `duplicateRegion`. Normalized PDF coords are
    /// rotation-independent (rotation is a display transform), so a clamp
    /// to [0, 1]² covers every page-size / rotation combination. Right
    /// edge is bounded by `1 - width`; bottom edge is bounded by 0.
    /// Pure function — testable without a full RedactionState.
    static func duplicateOffsetClamp(source: CGRect) -> CGRect {
        let offset: CGFloat = 0.02
        return CGRect(
            x: min(source.minX + offset, 1 - source.width),
            y: max(source.minY - offset, 0),
            width: source.width,
            height: source.height
        )
    }

    // MARK: - Undo Helper

    /// An Undo or Redo step as the editor shows it.
    struct UndoRedoStep: Equatable {
        var pages: Set<Int>
        let name: String
        let serial: Int
    }

    /// The pages the last Undo or Redo step changed.
    var lastUndoRedoPages: Set<Int> { lastUndoRedo?.pages ?? [] }

    /// Register an undoable action. Under the app target's SE-0466 MainActor
    /// default, `RedactionState` — and this method — are MainActor
    /// isolated, as is `UndoManager.registerUndo` on iOS 26. The `handler` is
    /// typed `@MainActor` because every handler body mutates MainActor region
    /// state and re-registers the inverse action; they already executed on
    /// MainActor via the `assumeIsolated` wrappers below, so the annotation
    /// makes the type system agree without changing runtime behavior. The inner
    /// `MainActor.assumeIsolated` still bridges the iOS-26
    /// `registerUndo(withTarget:)` callback (whose handler is not statically
    /// MainActor-typed).
    func registerUndo(
        _ undoManager: UndoManager?, _ actionName: String,
        handler: @escaping @MainActor (RedactionState) -> Void
    ) {
        guard let undoManager else { return }
        nonisolated(unsafe) let target = self
        MainActor.assumeIsolated {
            undoManager.registerUndo(withTarget: target) { target in
                MainActor.assumeIsolated {
                    let before = target.regions
                    handler(target)
                    target.recordUndoRedo(before: before, name: actionName)
                }
            }
            undoManager.setActionName(actionName)
        }
    }

    /// Records the step `name` names: the pages whose regions it changed.
    func recordUndoRedo(before: [Int: [RedactionRegion]], name: String) {
        let touched = Set(before.keys).union(regions.keys).filter { before[$0] != regions[$0] }
        if undoRedoStepOpen, var step = lastUndoRedo {
            step.pages.formUnion(touched)
            lastUndoRedo = step
        } else {
            lastUndoRedo = UndoRedoStep(pages: touched, name: name, serial: (lastUndoRedo?.serial ?? 0) + 1)
            undoRedoStepOpen = true
            Task { @MainActor [weak self] in self?.undoRedoStepOpen = false }
        }
    }
}
