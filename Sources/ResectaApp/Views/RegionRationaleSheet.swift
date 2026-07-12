import SwiftUI
import RedactionEngine

// WU-71 / [P10] path (a) — canvas-side rationale viewer. Mirrors
// `RegionInfoPopover`'s "View rationale" disclosure but as a full sheet
// for the iPhone canvas long-press flow. The view is presented from
// `DocumentEditorView` via `.sheet(item:)` keyed on
// `RedactionState.pendingCanvasRationaleRequest`. Copy is
// mechanism-description only — no matched-text echo.

/// Identifier wrapper that drives the `.sheet(item:)` presentation of
/// `RegionRationaleSheet` for a single canvas-tapped region. Mirrors
/// `RegionTagRequest`.
struct RegionRationaleRequest: Identifiable, Equatable {
    let regionID: UUID
    var id: UUID { regionID }
}

struct RegionRationaleSheet: View {
    let rationale: MatchRationale
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                // Human detector name via the shared
                // DetectorNameCatalog; raw ruleID kept beneath for audit
                // correlation (suppressed only when it would duplicate
                // the fail-open raw rendering).
                Section("Detector") {
                    VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                        Text(DetectorNameCatalog.displayName(forRuleID: rationale.ruleID))
                            .foregroundStyle(.secondary)
                        if DetectorNameCatalog.humanName(forRuleID: rationale.ruleID) != nil {
                            Text(rationale.ruleID)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Detector: \(DetectorNameCatalog.displayName(forRuleID: rationale.ruleID))")
                }
                Section("Score") {
                    scoreRow(label: "Detector score (before threshold)", value: rationale.preThresholdScore)
                    scoreRow(label: "Detector score (final)", value: rationale.finalScore)
                    if let threshold = rationale.appliedThreshold {
                        scoreRow(label: "Required threshold", value: threshold)
                    }
                }
                if !rationale.signals.isEmpty {
                    Section("Signals") {
                        ForEach(Array(rationale.signals.enumerated()), id: \.offset) { _, signal in
                            Text(Self.signalSummary(signal))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Match rationale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }

    private func scoreRow(label: String, value: Double) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(RegionInfoPopover.formatScore(value))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(RegionInfoPopover.formatScore(value))")
    }

    /// Compact text summary of a signal. No matched-text echoes — every
    /// case renders mechanism-description text plus engine-derived
    /// scalars (PIICategory rawValue, multipliers, scores).
    static func signalSummary(_ signal: MatchRationale.Signal) -> String {
        switch signal {
        // Signal names are usually engine ruleIDs; route through
        // the shared catalog (fail-open to the raw name).
        case .regexPattern(let name):
            return "Regex pattern: \(DetectorNameCatalog.displayName(forRuleID: name))"
        case .structuralValidator(let name):
            return "Structural validator: \(DetectorNameCatalog.displayName(forRuleID: name))"
        case .contextPositive(let score):          return "Positive context (+\(scoreString(score)))"
        case .contextNegative(let multiplier):     return "Negative context (×\(scoreString(multiplier)))"
        case .bloomSurnameHit:                     return "Surname hit"
        case .bloomGivenHit:                       return "Given-name hit"
        case .bloomFuzzySurnameHit(let score):     return "Fuzzy surname hit (\(scoreString(score)))"
        case .doctypeGate(let doctype):            return "Doctype gate: \(doctype.rawValue)"
        case .presetThresholdPass(let raw, let cutoff):
            return "Threshold pass (raw \(scoreString(raw)) vs \(scoreString(cutoff)))"
        case .ocrConfidence(let value):            return "OCR confidence: \(scoreString(value))"
        case .userAlwaysFlag:                      return "User always-flag pattern"
        case .userNeverFlag:                       return "User never-flag pattern"
        case .suppressedByOverlap(let winner, let loser):
            // QW-5 — label the suppressed match as its own category when
            // the signal carries it; older signals fall back to the
            // winner-only copy.
            if let loser {
                return "\(loser.rawValue), suppressed via \(winner.rawValue) overlap"
            }
            return "Overlap winner: \(winner.rawValue)"
        case .contextPositiveDetail(let keywords):
            // WU-76 / [P4] — keywordKey from gazetteer/profile (RR-31).
            // Using a for-loop rather than .map { String(format:) } —
            // the closure form has surfaced a runtime crash in
            // simulator-test contexts; loop form is the workaround.
            var parts: [String] = []
            for entry in keywords {
                let pct = Int((entry.contribution * 100).rounded())
                parts.append("'\(entry.keywordKey)' (+\(pct)%)")
            }
            return "Context: \(parts.joined(separator: ", "))"
        case .contextNegativeDetail(let keywords):
            var parts: [String] = []
            for entry in keywords {
                let pct = Int((entry.contribution * 100).rounded())
                parts.append("'\(entry.keywordKey)' (-\(pct)%)")
            }
            return "Negative context: \(parts.joined(separator: ", "))"
        case .negativeContextSuppressed(let keyword, let weight):
            // Gazetteer suppression signal.
            // The keyword is gazetteer data, not document content.
            return "Gazetteer negative context: '\(keyword)' (weight \(scoreString(weight)))"
        }
    }

    private static func scoreString(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
