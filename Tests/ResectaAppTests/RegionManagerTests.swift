import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// Region manager tests.

@Suite("RedactionState Region Manager")
@MainActor
struct RegionManagerTests {

    // MARK: - Effective Region Count

    @Test("effectiveRegionCount filters sub-threshold regions")
    func effectiveCountFiltering() {
        let state = RedactionState()
        let tinyRegion = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0.0005, height: 0.0005),
            source: .manual
        )
        let normalRegion = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            source: .manual
        )
        state.regions[0] = [tinyRegion, normalRegion]
        #expect(state.effectiveRegionCount == 1)
        #expect(state.hasEffectiveRegions == true)
    }

    @Test("effectiveRegionCount is zero when all regions are sub-threshold")
    func effectiveCountAllTiny() {
        let state = RedactionState()
        state.regions[0] = [
            RedactionRegion(id: UUID(),
                normalizedRect: CGRect(x: 0, y: 0, width: 0.0001, height: 0.0001),
                source: .manual)
        ]
        #expect(state.effectiveRegionCount == 0)
        #expect(state.hasEffectiveRegions == false)
    }

    // MARK: - regionsModifiedSinceVerification flag

    @Test("addRegion sets stale verification flag")
    func addSetsStaleFlag() {
        let state = RedactionState()
        let region = makeRegion()
        state.addRegion(region, page: 0, undoManager: nil)
        #expect(state.regionsModifiedSinceVerification == true)
        #expect(state.isVerificationStale == true)
    }

    @Test("markVerificationCurrent clears stale flag")
    func markCurrentClearsFlag() {
        let state = RedactionState()
        state.addRegion(makeRegion(), page: 0, undoManager: nil)
        #expect(state.isVerificationStale == true)
        state.markVerificationCurrent()
        #expect(state.isVerificationStale == false)
    }

    @Test("removeRegion sets stale flag")
    func removeSetsStaleFlag() {
        let state = RedactionState()
        let region = makeRegion()
        state.addRegion(region, page: 0, undoManager: nil)
        state.markVerificationCurrent()
        state.removeRegion(region.id, page: 0, undoManager: nil)
        #expect(state.isVerificationStale == true)
    }

    @Test("resizeRegion sets stale flag")
    func resizeSetsStaleFlag() {
        let state = RedactionState()
        let region = makeRegion()
        state.addRegion(region, page: 0, undoManager: nil)
        state.markVerificationCurrent()
        state.resizeRegion(region.id, page: 0,
            newRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
            undoManager: nil)
        #expect(state.isVerificationStale == true)
    }

    // MARK: - Add / Remove / Resize (no undo manager)

    @Test("addRegion appends to correct page")
    func addRegionToPage() {
        let state = RedactionState()
        let r1 = makeRegion()
        let r2 = makeRegion()
        state.addRegion(r1, page: 0, undoManager: nil)
        state.addRegion(r2, page: 1, undoManager: nil)
        #expect(state.regions[0]?.count == 1)
        #expect(state.regions[1]?.count == 1)
    }

    @Test("removeRegion removes by UUID")
    func removeByUUID() {
        let state = RedactionState()
        let r1 = makeRegion()
        let r2 = makeRegion()
        state.addRegion(r1, page: 0, undoManager: nil)
        state.addRegion(r2, page: 0, undoManager: nil)
        state.removeRegion(r1.id, page: 0, undoManager: nil)
        #expect(state.regions[0]?.count == 1)
        #expect(state.regions[0]?.first?.id == r2.id)
    }

    @Test("resizeRegion updates normalizedRect")
    func resizeUpdatesRect() {
        let state = RedactionState()
        let region = makeRegion()
        state.addRegion(region, page: 0, undoManager: nil)
        let newRect = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        state.resizeRegion(region.id, page: 0, newRect: newRect, undoManager: nil)
        #expect(state.regions[0]?.first?.normalizedRect == newRect)
    }

    // MARK: - Add / Remove with Undo
    // Note: UndoManager.groupsByEvent must be false in tests (no run loop).
    // Each operation wrapped in explicit begin/endUndoGrouping to isolate actions.

    @Test("addRegion undo removes the region")
    func addUndo() {
        let state = RedactionState()
        let undoManager = makeUndoManager()
        let region = makeRegion()
        withUndoGroup(undoManager) {
            state.addRegion(region, page: 0, undoManager: undoManager)
        }
        #expect(state.regions[0]?.count == 1)
        undoManager.undo()
        #expect(state.regions[0]?.count == 0)
    }

    @Test("removeRegion undo restores the region")
    func removeUndo() {
        let state = RedactionState()
        let undoManager = makeUndoManager()
        let region = makeRegion()
        withUndoGroup(undoManager) {
            state.addRegion(region, page: 0, undoManager: undoManager)
        }
        withUndoGroup(undoManager) {
            state.removeRegion(region.id, page: 0, undoManager: undoManager)
        }
        #expect(state.regions[0]?.count == 0)
        undoManager.undo()  // Undoes only removeRegion
        #expect(state.regions[0]?.count == 1)
        #expect(state.regions[0]?.first?.id == region.id)
    }

    @Test("resizeRegion undo restores original rect")
    func resizeUndo() {
        let state = RedactionState()
        let undoManager = makeUndoManager()
        let region = makeRegion()
        let originalRect = region.normalizedRect
        withUndoGroup(undoManager) {
            state.addRegion(region, page: 0, undoManager: undoManager)
        }
        withUndoGroup(undoManager) {
            state.resizeRegion(region.id, page: 0,
                newRect: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1),
                undoManager: undoManager)
        }
        undoManager.undo()  // Undoes only resize
        #expect(state.regions[0]?.first?.normalizedRect == originalRect)
    }

    // MARK: - Batch Apply Detection Results

    // Reshaped to the unified apply path: the raw detection map is the
    // detectionResults origin of `applyFindings` (async entry).
    @Test("Detection-map apply adds regions for multiple pages")
    func batchApply() async {
        let state = RedactionState()
        let det0 = DetectionResult(
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            kind: .pii(.ssn), confidence: 0.95)
        let det1 = DetectionResult(
            normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.1),
            kind: .face, confidence: 0.88)
        await state.applyFindings(.detectionResults([0: [det0], 1: [det1]]), undoManager: nil)
        #expect(state.regions[0]?.count == 1)
        #expect(state.regions[1]?.count == 1)
        #expect(state.regions[0]?.first?.source == .detectedPII(kind: .ssn))
        #expect(state.regions[1]?.first?.source == .detectedFace)
    }

    @Test("Detection-map apply undo removes all batch regions")
    func batchApplyUndo() async {
        let state = RedactionState()
        let undoManager = makeUndoManager()
        let det = DetectionResult(
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            kind: .pii(.ssn), confidence: 0.95)
        undoManager.beginUndoGrouping()
        await state.applyFindings(.detectionResults([0: [det]]), undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(state.regions[0]?.count == 1)
        undoManager.undo()
        #expect(state.regions[0]?.isEmpty != false)
    }

    // MARK: - Output URL Clearing

    @Test("addRegion clears outputURL")
    func addClearsOutput() {
        let state = RedactionState()
        state.outputURL = URL(fileURLWithPath: "/tmp/test.pdf")
        state.addRegion(makeRegion(), page: 0, undoManager: nil)
        #expect(state.outputURL == nil)
    }

    @Test("clearOutput deletes file and clears textExtractionBuffer")
    func clearOutputResetsAll() {
        let state = RedactionState()
        state.outputURL = URL(fileURLWithPath: "/tmp/nonexistent.pdf")
        state.addRegion(makeRegion(), page: 0, undoManager: nil)
        state.clearOutput()
        #expect(state.outputURL == nil)
        #expect(state.textExtractionBuffer == nil)
        // clearOutput no longer touches the
        // `regionsModifiedSinceVerification` flag. addRegion set the
        // flag to true above; clearOutput preserves it because the
        // regions are still modified relative to the last (now
        // discarded) verification. The flag resets only via
        // `markVerificationCurrent()` (called by the pipeline runner
        // after a successful verify) or `clearForNewDocument()` /
        // `clearAll()` (full-document reset).
        #expect(state.isVerificationStale == true)
    }

    @Test("clearVerification does NOT clear outputURL (SER-6)")
    func clearVerificationPreservesOutput() {
        let state = RedactionState()
        let url = URL(fileURLWithPath: "/tmp/test.pdf")
        state.outputURL = url
        state.clearVerification()
        #expect(state.outputURL == url)
    }

    // MARK: - Region mutations unlink the previous output

    // Every region mutation routes through `clearOutput()`: the previous
    // output file is unlinked at once (not left for the launch sweep), the
    // published URL is nil, and the retained run inputs are dropped — the
    // output they described no longer exists, and the verify-only path
    // re-derives its inputs when they are nil. The three undo/redo
    // closures that mutate through `target` / `target2` are pinned by the
    // two lifecycle tests at the end.

    /// Write a real file, register it as the output, and record run
    /// inputs, so a mutation has something to unlink and something to drop.
    private func seedOutput(_ state: RedactionState) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("redacted_\(UUID().uuidString).pdf")
        try Data("output".utf8).write(to: url)
        state.outputURL = url
        state.recordLastRunInputs(
            perPageModes: [.secureRasterization],
            perPageFallbackReasons: [nil],
            sensitiveTerms: [],
            appliedSearches: [])
        state.textExtractionBuffer = [:]
        return url
    }

    private func expectOutputUnlinked(
        _ state: RedactionState, _ url: URL, _ leg: String
    ) {
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "\(leg): the previous output file is unlinked at once")
        #expect(state.outputURL == nil, "\(leg): the published URL is nil")
        #expect(state.lastRunAppliedSearches == nil,
                "\(leg): the retained applied searches are dropped")
        #expect(state.lastRunPerPageModes == nil,
                "\(leg): the retained per-page modes are dropped")
        #expect(state.textExtractionBuffer == nil,
                "\(leg): the extraction buffer is dropped")
    }

    @Test("addRegion unlinks the previous output file and drops the retained run inputs")
    func addRegionUnlinksOutput() throws {
        let state = RedactionState()
        let url = try seedOutput(state)
        defer { try? FileManager.default.removeItem(at: url) }
        state.addRegion(makeRegion(), page: 0, undoManager: nil)
        expectOutputUnlinked(state, url, "addRegion")
    }

    @Test("removeRegion unlinks the previous output file and drops the retained run inputs")
    func removeRegionUnlinksOutput() throws {
        let state = RedactionState()
        let region = makeRegion()
        state.addRegion(region, page: 0, undoManager: nil)
        let url = try seedOutput(state)
        defer { try? FileManager.default.removeItem(at: url) }
        state.removeRegion(region.id, page: 0, undoManager: nil)
        expectOutputUnlinked(state, url, "removeRegion")
    }

    @Test("resizeRegion unlinks the previous output file and drops the retained run inputs")
    func resizeRegionUnlinksOutput() throws {
        let state = RedactionState()
        let region = makeRegion()
        state.addRegion(region, page: 0, undoManager: nil)
        let url = try seedOutput(state)
        defer { try? FileManager.default.removeItem(at: url) }
        state.resizeRegion(
            region.id, page: 0,
            newRect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5),
            undoManager: nil)
        expectOutputUnlinked(state, url, "resizeRegion")
    }

    @Test("moveRegion unlinks the previous output file and drops the retained run inputs")
    func moveRegionUnlinksOutput() throws {
        let state = RedactionState()
        let region = makeRegion()
        state.addRegion(region, page: 0, undoManager: nil)
        let url = try seedOutput(state)
        defer { try? FileManager.default.removeItem(at: url) }
        state.moveRegion(
            region.id, page: 0,
            newRect: CGRect(x: 0.4, y: 0.4, width: 0.3, height: 0.4),
            undoManager: nil)
        expectOutputUnlinked(state, url, "moveRegion")
    }

    @Test("moveRegions unlinks the previous output file and drops the retained run inputs")
    func moveRegionsUnlinksOutput() throws {
        let state = RedactionState()
        let a = makeRegion()
        let b = makeRegion(rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.1))
        state.addRegion(a, page: 0, undoManager: nil)
        state.addRegion(b, page: 0, undoManager: nil)
        let url = try seedOutput(state)
        defer { try? FileManager.default.removeItem(at: url) }
        state.moveRegions(
            [(id: a.id, newRect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.4)),
             (id: b.id, newRect: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.1))],
            page: 0, undoManager: nil)
        expectOutputUnlinked(state, url, "moveRegions")
    }

    @Test("removeRegions unlinks the previous output file and drops the retained run inputs")
    func removeRegionsUnlinksOutput() throws {
        let state = RedactionState()
        let a = makeRegion()
        let b = makeRegion(rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.1))
        state.addRegion(a, page: 0, undoManager: nil)
        state.addRegion(b, page: 0, undoManager: nil)
        let url = try seedOutput(state)
        defer { try? FileManager.default.removeItem(at: url) }
        state.removeRegions([a.id, b.id], page: 0, undoManager: nil)
        expectOutputUnlinked(state, url, "removeRegions")
    }

    @Test("The apply path unlinks the previous output file and drops the retained run inputs")
    func applyUnlinksOutput() async throws {
        let state = RedactionState()
        let url = try seedOutput(state)
        defer { try? FileManager.default.removeItem(at: url) }
        let det = DetectionResult(
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            kind: .pii(.ssn), confidence: 0.95)
        await state.applyFindings(.detectionResults([0: [det]]), undoManager: nil)
        #expect(state.regions[0]?.count == 1)
        expectOutputUnlinked(state, url, "apply")
    }

    @Test("removeRegions undo and redo each unlink the output registered since the previous leg")
    func removeRegionsUndoRedoUnlinkOutput() throws {
        let state = RedactionState()
        let undoManager = makeUndoManager()
        let a = makeRegion()
        let b = makeRegion(rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.1))
        state.addRegion(a, page: 0, undoManager: nil)
        state.addRegion(b, page: 0, undoManager: nil)
        undoManager.beginUndoGrouping()
        state.removeRegions([a.id, b.id], page: 0, undoManager: undoManager)
        undoManager.endUndoGrouping()

        // Undo re-inserts through the closure's `target`.
        let afterRemove = try seedOutput(state)
        defer { try? FileManager.default.removeItem(at: afterRemove) }
        undoManager.undo()
        #expect(state.regions[0]?.count == 2)
        expectOutputUnlinked(state, afterRemove, "removeRegions undo")

        // Redo removes again through the nested closure's `target2`.
        let afterUndo = try seedOutput(state)
        defer { try? FileManager.default.removeItem(at: afterUndo) }
        undoManager.redo()
        #expect(state.regions[0]?.isEmpty != false)
        expectOutputUnlinked(state, afterUndo, "removeRegions redo")
    }

    @Test("Apply undo and redo each unlink the output registered since the previous leg")
    func applyUndoRedoUnlinkOutput() async throws {
        let state = RedactionState()
        let undoManager = makeUndoManager()
        let det = DetectionResult(
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            kind: .pii(.ssn), confidence: 0.95)
        undoManager.beginUndoGrouping()
        await state.applyFindings(.detectionResults([0: [det]]), undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(state.regions[0]?.count == 1)

        // Undo removes the created regions through the closure's `target`.
        let afterApply = try seedOutput(state)
        defer { try? FileManager.default.removeItem(at: afterApply) }
        undoManager.undo()
        #expect(state.regions[0]?.isEmpty != false)
        expectOutputUnlinked(state, afterApply, "apply undo")

        // Redo re-inserts them through the nested closure's `target2`.
        let afterUndo = try seedOutput(state)
        defer { try? FileManager.default.removeItem(at: afterUndo) }
        undoManager.redo()
        #expect(state.regions[0]?.count == 1)
        expectOutputUnlinked(state, afterUndo, "apply redo")
    }

    // MARK: - Clear and Multi-Page

    @Test("clearForNewDocument resets all state")
    func clearForNewDocumentResetsAll() {
        let state = RedactionState()
        state.addRegion(makeRegion(), page: 0, undoManager: nil)
        state.addRegion(makeRegion(), page: 1, undoManager: nil)
        state.outputURL = URL(fileURLWithPath: "/tmp/test.pdf")

        state.clearForNewDocument()

        #expect(state.regions.isEmpty || state.regions.values.allSatisfy { $0.isEmpty })
        #expect(state.detectionResults.isEmpty)
        #expect(state.selectedRegionID == nil)
        #expect(state.outputURL == nil)
        #expect(state.isVerificationStale == false)
    }

    @Test("effectiveRegionCount sums across pages")
    func regionCountMultiPage() {
        let state = RedactionState()
        state.addRegion(makeRegion(), page: 0, undoManager: nil)
        state.addRegion(makeRegion(), page: 0, undoManager: nil)
        state.addRegion(makeRegion(), page: 1, undoManager: nil)
        #expect(state.effectiveRegionCount == 3)
    }

    @Test("Detection-map apply creates regions with correct source types")
    func applyDetectionResultsCreatesCorrectSources() async {
        let state = RedactionState()
        let ssn = DetectionResult(
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
            kind: .pii(.creditCard), confidence: 0.9)
        let face = DetectionResult(
            normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
            kind: .face, confidence: 0.85)
        await state.applyFindings(.detectionResults([0: [ssn, face]]), undoManager: nil)
        #expect(state.regions[0]?.count == 2)
        #expect(state.regions[0]?[0].source == .detectedPII(kind: .creditCard))
        #expect(state.regions[0]?[1].source == .detectedFace)
    }

    // MARK: - Triage

    @Test("Staged-review apply creates regions and metadata, undo/redo lifecycle")
    func triageApplyUndoMetadata() async {
        let state = RedactionState()
        let undoManager = makeUndoManager()
        let detection = DetectionResult.mock(kind: .pii(.ssn), matchedText: "123-45-6789")
        state.pendingTriage = [0: [detection]]
        state.triageSelections = [detection.id: true]

        undoManager.beginUndoGrouping()
        await state.applyFindings(.stagedDetections, undoManager: undoManager)
        undoManager.endUndoGrouping()
        let regionID = state.regions[0]!.first!.id
        #expect(state.regionMetadata[regionID] != nil)
        #expect(state.regionMetadata[regionID]?.matchedText == "123-45-6789")
        #expect(state.pendingTriage == nil)
        #expect(state.triageSelections.isEmpty)

        undoManager.undo()
        #expect(state.regions[0]?.isEmpty ?? true)
        #expect(state.regionMetadata[regionID] == nil)

        undoManager.redo()
        #expect(state.regions[0]?.count == 1)
        #expect(state.regionMetadata[regionID] != nil)
    }

    @Test("Staged-review apply filters rejected detections")
    func triageFiltersRejected() async {
        let state = RedactionState()
        let accepted = DetectionResult.mock(kind: .pii(.ssn))
        let rejected = DetectionResult.mock(kind: .pii(.email))
        state.pendingTriage = [0: [accepted, rejected]]
        state.triageSelections = [accepted.id: true, rejected.id: false]

        await state.applyFindings(.stagedDetections, undoManager: nil)
        #expect(state.regions[0]?.count == 1)
        #expect(state.regionMetadata.count == 1)
    }

    @Test("dismissTriage clears pending state without applying")
    func dismissTriageClearsState() {
        let state = RedactionState()
        state.pendingTriage = [0: [.mock()]]
        state.triageSelections = [UUID(): true]

        state.dismissTriage()
        #expect(state.pendingTriage == nil)
        #expect(state.triageSelections.isEmpty)
    }

    // MARK: - Remove Region Metadata Cleanup

    @Test("removeRegion cleans up regionMetadata and restores on undo")
    func removeRegionCleansUpMetadata() {
        let state = RedactionState()
        let undoManager = makeUndoManager()
        let region = makeRegion()

        withUndoGroup(undoManager) {
            state.addRegion(region, page: 0, undoManager: undoManager)
        }
        state.regionMetadata[region.id] = .mock()
        #expect(state.regionMetadata[region.id] != nil)

        withUndoGroup(undoManager) {
            state.removeRegion(region.id, page: 0, undoManager: undoManager)
        }
        #expect(state.regionMetadata[region.id] == nil)

        undoManager.undo()  // Undoes removeRegion
        #expect(state.regions[0]?.contains { $0.id == region.id } == true)
        #expect(state.regionMetadata[region.id] != nil)
    }

    // MARK: - Full Reset

    @Test("clearAll resets all state to initial values")
    func clearAllResetsState() {
        let state = RedactionState()
        state.regions = [0: [.mock()]]
        state.detectionResults = [0: [.mock()]]
        state.selectedRegionID = UUID()
        state.pendingTriage = [0: [.mock()]]
        state.triageSelections = [UUID(): true]
        state.regionMetadata = [UUID(): .mock()]
        state.outputURL = URL(fileURLWithPath: "/tmp/test.pdf")

        state.clearAll()
        #expect(state.regions.isEmpty)
        #expect(state.detectionResults.isEmpty)
        #expect(state.selectedRegionID == nil)
        #expect(state.pendingTriage == nil)
        #expect(state.triageSelections.isEmpty)
        #expect(state.regionMetadata.isEmpty)
        #expect(state.outputURL == nil)
    }

    // MARK: - Helpers

    private func makeRegion(
        rect: CGRect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
    ) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual)
    }
}
