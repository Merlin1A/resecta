import Foundation
import RedactionEngine

/// One enumeration of a report's layers into the details disclosure's
/// groups, top to bottom — FINDINGS (failed · needs review · warning),
/// COULD NOT VERIFY, NOTES (a note with items remaining · nothing to check)
/// and the pass cluster (passed · a note with nothing remaining) — with the
/// per-outcome counts the summary line prints. Each layer's outcome is
/// `VerificationRowModel.outcome(for:perPageModes:)`. Indices are engine
/// positions (0-based), in engine order inside every group, so the rows'
/// `layerResult_N` identifiers stay index-keyed across grouping;
/// `report.layers[i]` is the row.
// nonisolated: a pure value over engine types, read by the section on the
// MainActor and by the display tests; nothing here is actor state.
nonisolated struct VerificationLayerPartition: Equatable {
    let findings: [Int]
    let couldNotVerify: [Int]
    let notes: [Int]
    let cluster: [Int]
    /// Every layer's outcome, by engine index.
    let outcomes: [VerificationOutcome]

    var total: Int { outcomes.count }

    func count(_ outcome: VerificationOutcome) -> Int {
        outcomes.count { $0 == outcome }
    }

    /// Only a passing check counts as passed — never a note, a check that
    /// had nothing to check or one that could not verify.
    var passedCount: Int { count(.passed) }
    /// The notes that ride inside the cluster (nothing remaining).
    var clusterNoteCount: Int { cluster.count { outcomes[$0] == .note } }
    /// Nothing sits above the cluster: it opens by default.
    var isWhollyClean: Bool { findings.isEmpty && couldNotVerify.isEmpty && notes.isEmpty }

    init(layers: [LayerResult], perPageModes: [PipelineMode]) {
        var findings: [Int] = []
        var couldNotVerify: [Int] = []
        var notes: [Int] = []
        var cluster: [Int] = []
        var outcomes: [VerificationOutcome] = []
        for (index, layer) in layers.enumerated() {
            let outcome = VerificationRowModel.outcome(for: layer, perPageModes: perPageModes)
            outcomes.append(outcome)
            // Exhaustive so a new outcome must choose its group here.
            switch outcome {
            case .failed, .needsReview, .warning:
                findings.append(index)
            case .couldNotVerify:
                couldNotVerify.append(index)
            case .nothingToCheck:
                notes.append(index)
            case .note:
                if VerificationRowModel.hasItemsRemaining(layer) {
                    notes.append(index)
                } else {
                    cluster.append(index)
                }
            case .passed:
                cluster.append(index)
            }
        }
        self.findings = findings
        self.couldNotVerify = couldNotVerify
        self.notes = notes
        self.cluster = cluster
        self.outcomes = outcomes
    }

    /// The summary line: "{P} of {T} checks passed", then one clause per
    /// other outcome present, in `VerificationOutcome.headerClauseOrder`.
    var summaryText: String {
        let clauses = VerificationOutcome.headerClauseOrder.compactMap { $0.headerClause(count: count($0)) }
        return (["\(passedCount) of \(total) checks passed"] + clauses).joined(separator: " · ")
    }

    /// The pass cluster's row title: "N checks passed" / "1 check passed",
    /// then " · 1 note" / " · K notes" when notes ride inside it.
    var clusterTitle: String {
        let passed = passedCount == 1 ? "1 check passed" : "\(passedCount) checks passed"
        guard let notes = VerificationOutcome.note.headerClause(count: clusterNoteCount) else { return passed }
        return "\(passed) · \(notes)"
    }
}
