import Foundation
import RedactionEngine

/// One enumeration of a report's layers into the details disclosure's
/// groups, top to bottom — Findings (failed · needs review · warning),
/// Could not verify, Notes (a note with items remaining), Nothing to check
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
    let nothingToCheck: [Int]
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
    var isWhollyClean: Bool {
        findings.isEmpty && couldNotVerify.isEmpty && notes.isEmpty && nothingToCheck.isEmpty
    }

    init(layers: [LayerResult], perPageModes: [PipelineMode]) {
        var findings: [Int] = []
        var couldNotVerify: [Int] = []
        var notes: [Int] = []
        var nothingToCheck: [Int] = []
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
                nothingToCheck.append(index)
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
        self.nothingToCheck = nothingToCheck
        self.cluster = cluster
        self.outcomes = outcomes
    }

    /// The summary's first line: "{P} of {T} checks passed" ("0 of 1 check
    /// passed" when T = 1).
    var summaryLine1: String {
        "\(passedCount) of \(total) \(total == 1 ? "check" : "checks") passed"
    }

    /// The summary's second line: one clause per other outcome present, in
    /// `VerificationOutcome.headerClauseOrder`; nil when every row passed.
    var summaryLine2: String? {
        let clauses = VerificationOutcome.headerClauseOrder.compactMap { $0.headerClause(count: count($0)) }
        return clauses.isEmpty ? nil : clauses.joined(separator: " · ")
    }

    /// The one-line summary: line 1, then line 2's clauses.
    var summaryText: String {
        ([summaryLine1] + (summaryLine2.map { [$0] } ?? [])).joined(separator: " · ")
    }

    /// A group's header with its count: "Findings · 3".
    static func sectionHeader(_ header: String, count: Int) -> String {
        "\(header) · \(count)"
    }

    /// The header's spoken form: "Findings, 3.".
    static func sectionHeaderSpoken(_ header: String, count: Int) -> String {
        "\(header), \(count)."
    }

    /// The pass cluster's row title: "N checks passed" / "1 check passed",
    /// then " · 1 note" / " · K notes" when notes ride inside it.
    var clusterTitle: String {
        let passed = passedCount == 1 ? "1 check passed" : "\(passedCount) checks passed"
        guard let notes = VerificationOutcome.note.headerClause(count: clusterNoteCount) else { return passed }
        return "\(passed) · \(notes)"
    }

    /// The cluster's spoken title: "9 checks passed, 1 note".
    var clusterSpokenLabel: String {
        clusterTitle.replacingOccurrences(of: " · ", with: ", ")
    }
}
