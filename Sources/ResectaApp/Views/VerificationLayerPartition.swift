import Foundation
import RedactionEngine

/// One enumeration of a report's layers into the details disclosure's
/// three groups — FINDINGS (warn · attention · fail · skipped, in engine
/// order), the clean checks (pass) and NOTES (info) — with the counts the
/// summary line prints. Indices are engine positions (0-based), so the
/// rows' `layerResult_N` identifiers and the spoken "Layer N" stay
/// index-keyed across grouping; `report.layers[i]` is the row.
///
/// `.skipped` rides under FINDINGS (a skipped check is something the user
/// should notice), never silently in the passed group; `.info` rides under
/// NOTES and also counts as passed (no actionable issue) — the shape the
/// disclosure has always shown.
// nonisolated: a pure value over engine types, read by the section on the
// MainActor and by the display tests; nothing here is actor state.
nonisolated struct VerificationLayerPartition: Equatable {
    /// warn · attention · fail · skipped — engine order, not grouped by kind.
    let findings: [Int]
    /// pass.
    let passed: [Int]
    /// info.
    let notes: [Int]
    let total: Int
    let infoCount: Int
    let skippedCount: Int
    let warnCount: Int
    let attentionCount: Int
    let failCount: Int

    /// "Passed" counts pass + info (no actionable issue). `.skipped` is
    /// surfaced separately — never rolled into the passed count.
    var passedCount: Int { passed.count + notes.count }
    /// Every layer that ran — the WARN arm's "completed" tally (a note is
    /// a note, not a failure).
    var completedCount: Int { total - skippedCount }
    /// No findings and no notes: the flat, header-less list.
    var isWhollyClean: Bool { findings.isEmpty && notes.isEmpty }

    init(layers: [LayerResult]) {
        var findings: [Int] = []
        var passed: [Int] = []
        var notes: [Int] = []
        var info = 0, skipped = 0, warn = 0, attention = 0, fail = 0
        for (index, layer) in layers.enumerated() {
            // Exhaustive so a new status must choose its group here.
            switch layer.status {
            case .pass:      passed.append(index)
            case .info:      notes.append(index);    info += 1
            case .warn:      findings.append(index); warn += 1
            case .attention: findings.append(index); attention += 1
            case .fail:      findings.append(index); fail += 1
            case .skipped:   findings.append(index); skipped += 1
            }
        }
        self.findings = findings
        self.passed = passed
        self.notes = notes
        self.total = layers.count
        self.infoCount = info
        self.skippedCount = skipped
        self.warnCount = warn
        self.attentionCount = attention
        self.failCount = fail
    }
}
