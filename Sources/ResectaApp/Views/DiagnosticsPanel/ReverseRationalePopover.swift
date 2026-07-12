import SwiftUI
import RedactionEngine

// W9 — "Why this match?" sheet. Accepts a snippet + bounded context buffer
// (≤500 chars) and runs every PIICategory detector through
// PIIDetector.reverseRationale. Scope contract surfaced in the footer so
// users don't conflate the result with full-document scoring.

struct ReverseRationaleRequest: Identifiable, Sendable {
    let id = UUID()
    let snippet: String
    let fullContext: String
    let doctype: DoctypeClass?
}

struct ReverseRationalePopover: View {
    let request: ReverseRationaleRequest
    @Environment(SettingsState.self) private var settingsState
    @Environment(UserTermsStore.self) private var userTermsStore
    @Environment(\.dismiss) private var dismiss
    @State private var rationale: ReverseRationale?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: ResectaTokens.Spacing.sm) {
                        ProgressView()
                        Text(String(localized: "reverseRationale.header", table: "Legal"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let rationale {
                    resultsList(rationale: rationale)
                } else {
                    ContentUnavailableView(
                        "No result",
                        systemImage: "questionmark.circle",
                        description: Text("Unable to score this text.")
                    )
                }
            }
            .navigationTitle(String(localized: "reverseRationale.title", table: "Legal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task(id: request.id) {
                await loadRationale()
            }
        }
    }

    @ViewBuilder
    private func resultsList(rationale: ReverseRationale) -> some View {
        List {
            Section {
                Text(rationale.snippet)
                    .font(.body.monospaced())
                    .privacySensitive()
                    .textSelection(.disabled)
            } header: {
                Text("Text")
            }

            Section {
                ForEach(rationale.considered, id: \.category) { row in
                    ConsiderationRow(result: row)
                }
            } header: {
                Text(String(localized: "reverseRationale.header", table: "Legal"))
            } footer: {
                Text(String(localized: "reverseRationale.scopeFooter", table: "Legal"))
            }
        }
    }

    private func loadRationale() async {
        isLoading = true
        // ERR-05 (Pkg N): route through `loadWithDiagnostics` so a
        // signed-manifest verification failure or per-gazetteer load
        // failure surfaces as the SEC-7 degraded-detection signal (the
        // banner-flip happens in PipelineCoordinator, not here — the
        // diagnostics value is discarded at this site because the W9
        // popover is read-only and the warning toast surface is owned
        // by the detection-pipeline runner). The point is to avoid
        // the silent corpus skip the bare `PIIDetector()` init produced
        // when a gazetteer was missing or its signature failed.
        let (detector, _) = PIIDetector.loadWithDiagnostics()
        // The rationale display must reflect the
        // user-selected preset, not a hardcoded `.balanced` — otherwise
        // the popover misstates the cutoffs a conservative/sensitive
        // user was actually gated by.
        let vector = settingsState.activeThresholdVector
        let matcher: UserTermMatcher? = {
            let compiled = UserTermMatcher.compile(
                alwaysFlag: userTermsStore.blob.alwaysFlag,
                neverFlag: userTermsStore.blob.neverFlag
            )
            return compiled.isEmpty ? nil : compiled
        }()
        let result = await detector.reverseRationale(
            for: request.snippet,
            fullContext: request.fullContext,
            doctype: request.doctype,
            thresholdVector: vector,
            userTerms: matcher
        )
        rationale = result
        isLoading = false
    }
}

private struct ConsiderationRow: View {
    let result: ConsiderationResult

    var body: some View {
        HStack(spacing: ResectaTokens.Spacing.sm) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.category.rawValue)
                    .font(.subheadline.weight(.medium))
                Text(reasonLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Human detector name via the shared catalog; raw
                // ruleID stays available in the tertiary position for
                // audit correlation (fail-open: unmapped IDs render raw,
                // so the raw line is suppressed only when it would
                // duplicate the display line).
                Text(DetectorNameCatalog.displayName(forRuleID: result.ruleID))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if DetectorNameCatalog.humanName(forRuleID: result.ruleID) != nil {
                    Text(result.ruleID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let score = result.finalScore {
                // Label both numbers: the detector's score vs the
                // preset threshold it needed to clear. These are NOT the
                // row's overall confidence — different quantities.
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Detector score \(String(format: "%.0f%%", score * 100))")
                        .font(.caption.monospacedDigit().weight(.medium))
                    if let threshold = result.threshold {
                        Text("needs ≥\(String(format: "%.0f", threshold * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var iconName: String {
        switch result.reason {
        case .aboveThreshold, .matchedAlwaysFlag: "checkmark.circle.fill"
        case .belowThreshold:                     "circle.slash"
        case .doctypeGated:                       "xmark.circle"
        case .suppressedByUserTerm:               "flag.slash"
        case .suppressedByOverlap:                "rectangle.stack"
        case .noMatch:                            "circle.dotted"
        case .snippetNotInContext:                "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch result.reason {
        case .aboveThreshold, .matchedAlwaysFlag:
            Color(uiColor: .systemGreen)
        case .belowThreshold:
            Color(uiColor: .systemOrange)
        case .suppressedByOverlap, .doctypeGated, .suppressedByUserTerm, .noMatch:
            .secondary
        case .snippetNotInContext:
            Color(uiColor: .systemYellow)
        }
    }

    private var reasonLabel: String {
        switch result.reason {
        case .aboveThreshold:       return "Matched"
        case .matchedAlwaysFlag:    return "Flagged by your terms"
        case .belowThreshold:       return "Score below threshold"
        case .doctypeGated:         return "Skipped for this doc type"
        case .suppressedByUserTerm: return "Excluded by your terms"
        case .suppressedByOverlap:
            if let winner = result.overlapWinner {
                return "Superseded by \(winner.rawValue)"
            }
            return "Superseded by another match"
        case .noMatch:              return "No match"
        case .snippetNotInContext:  return "Context missing"
        }
    }
}
