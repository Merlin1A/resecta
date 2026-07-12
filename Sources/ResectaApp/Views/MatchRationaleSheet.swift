import SwiftUI
import RedactionEngine

// W1 — power-user rationale disclosure for a single PII hit.
//
// Presented as a sheet from the info.circle accessory on a PII result row.
// Renders the rule ID, the signals the detector recorded, and the score
// journey from raw detector output to the final score.
//
// Language is strictly mechanism-descriptive:
// describe what the detector observed, not what the app "guarantees".

struct MatchRationaleSheet: View {
    let result: SearchResult
    @Environment(\.dismiss) private var dismiss

    init(result: SearchResult) {
        self.result = result
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    overviewRow
                    ruleRow
                    if let category = result.piiCategory {
                        categoryRow(category: category)
                    }
                } header: {
                    Text("Match")
                }

                rationaleSections(for: result)
            }
            .navigationTitle("Match rationale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func rationaleSections(for result: SearchResult) -> some View {
        if let rationale = result.rationale {
            // Every number gets a noun. "Detector score" is the
            // detector's internal signal; "Required threshold" is the
            // cutoff it had to clear; "Match confidence" is the separate
            // per-row quantity shown in the results list. Labeling all
            // three keeps a row confidence that differs from the detector
            // score from reading as a contradiction.
            Section {
                scoreRow(
                    label: "Detector score (before threshold)",
                    value: rationale.preThresholdScore
                )
                scoreRow(
                    label: "Detector score (final)",
                    value: rationale.finalScore
                )
                if let threshold = rationale.appliedThreshold {
                    scoreRow(label: "Required threshold", value: threshold)
                }
                if let confidence = result.piiConfidence {
                    scoreRow(label: "Match confidence (shown on row)", value: confidence)
                }
            } header: {
                Text("Score")
            } footer: {
                Text("The final detector score is what the detector compared against the required threshold. Match confidence is a separate per-match quantity shown in the results list. Values are descriptive of the detector's internal signal and are not a measure of outcome.")
                    .font(.caption2)
            }

            if !rationale.signals.isEmpty {
                Section {
                    ForEach(Array(rationale.signals.enumerated()), id: \.offset) { _, signal in
                        signalRow(signal: signal)
                    }
                } header: {
                    Text("Signals")
                }
            }
        }
    }

    // MARK: - Rows

    private var overviewRow: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
            Text(result.matchedText)
                .font(.subheadline.monospaced())
                .privacySensitive()
            Text(result.contextSnippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .privacySensitive()
        }
    }

    // Human detector name via the shared DetectorNameCatalog;
    // the raw engine ruleID stays visible beneath in a secondary
    // position (power users + audit correlation). Fail-open: an
    // unmapped ID renders raw on the primary line and the duplicate
    // secondary line is suppressed.
    private var ruleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Detector", systemImage: "scroll")
            Spacer()
            VStack(alignment: .trailing, spacing: ResectaTokens.Spacing.xxs) {
                Text(ruleDisplayName)
                    .foregroundStyle(.secondary)
                if let rawID = result.rationale?.ruleID,
                   DetectorNameCatalog.humanName(forRuleID: rawID) != nil {
                    Text(rawID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Detector: \(ruleDisplayName)")
    }

    private var ruleDisplayName: String {
        guard let ruleID = result.rationale?.ruleID else { return "—" }
        return DetectorNameCatalog.displayName(forRuleID: ruleID)
    }

    private func categoryRow(category: PIICategory) -> some View {
        HStack {
            Label("Category", systemImage: category.symbolName)
            Spacer()
            Text(category.rawValue)
                .foregroundStyle(.secondary)
        }
    }

    private func scoreRow(label: String, value: Double) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(Self.formatScore(value))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(Int((value * 100).rounded()))%")
    }

    @ViewBuilder
    private func signalRow(signal: MatchRationale.Signal) -> some View {
        let descriptor = Self.descriptor(for: signal)
        HStack(alignment: .top, spacing: ResectaTokens.Spacing.sm) {
            Image(systemName: descriptor.symbol)
                .foregroundStyle(descriptor.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                Text(descriptor.title)
                    .font(.subheadline)
                if let detail = descriptor.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(descriptor.title + (descriptor.detail.map { ", " + $0 } ?? ""))
    }

    // MARK: - Signal rendering

    /// WU-24 (session-11): visibility lifted from `private` to default
    /// (`internal`) so `MatchRationaleSheetContextKeywordTests` can pin
    /// the per-Signal descriptor format. The shape mirrors the row's
    /// rendering primitives — symbol + tint + title + optional detail.
    struct SignalDescriptor: Equatable {
        let symbol: String
        let tint: Color
        let title: String
        let detail: String?
    }

    /// WU-24: per-Signal descriptor for the rationale sheet's "Signals"
    /// section. Existing case mappings are unchanged from WU-01;
    /// promoted to `internal` so the test suite pins each scalar
    /// format. The `@unknown default:` case provides forward-compat
    /// with the future `.contextPositiveDetail` /
    /// `.contextNegativeDetail` keyword-array variants from WU-76 —
    /// when those land, this default becomes unreachable and the
    /// switch picks them up explicitly. Strings classified SAFE under
    /// §19 — every title + detail is mechanism description.
    static func descriptor(for signal: MatchRationale.Signal) -> SignalDescriptor {
        switch signal {
        case .regexPattern(let name):
            // Signal names are usually engine ruleIDs; route them
            // through the shared catalog (fail-open to the raw name).
            return SignalDescriptor(symbol: "text.magnifyingglass", tint: .blue,
                                    title: "Pattern matched",
                                    detail: DetectorNameCatalog.displayName(forRuleID: name))
        case .structuralValidator(let name):
            return SignalDescriptor(symbol: "checkmark.shield", tint: .green,
                                    title: "Structural validator accepted",
                                    detail: DetectorNameCatalog.displayName(forRuleID: name))
        case .contextPositive(let score):
            return SignalDescriptor(symbol: "arrow.up.right.circle", tint: .green,
                                    title: "Positive context keyword",
                                    detail: "raised score to \(formatScore(score))")
        case .contextNegative(let multiplier):
            return SignalDescriptor(symbol: "arrow.down.right.circle", tint: .orange,
                                    title: "Negative context keyword",
                                    detail: "applied ×\(String(format: "%.2f", multiplier))")
        case .bloomSurnameHit:
            return SignalDescriptor(symbol: "person.text.rectangle", tint: .mint,
                                    title: "Surname in gazetteer",
                                    detail: nil)
        case .bloomGivenHit:
            return SignalDescriptor(symbol: "person.crop.circle", tint: .mint,
                                    title: "Given name in gazetteer",
                                    detail: nil)
        case .bloomFuzzySurnameHit(let score):
            return SignalDescriptor(symbol: "person.text.rectangle", tint: .mint,
                                    title: "Fuzzy surname match",
                                    detail: "score multiplier \(String(format: "%.2f", score))")
        case .doctypeGate(let doctype):
            return SignalDescriptor(symbol: "doc.text", tint: .indigo,
                                    title: "Doctype gate",
                                    detail: doctype.rawValue)
        case .presetThresholdPass(let raw, let cutoff):
            return SignalDescriptor(symbol: "slider.horizontal.3", tint: ResectaTokens.BrandTeal.tint,
                                    title: "Preset threshold check",
                                    detail: "raw \(formatScore(raw)) vs cutoff \(formatScore(cutoff))")
        case .ocrConfidence(let value):
            return SignalDescriptor(symbol: "camera.viewfinder", tint: .teal,
                                    title: "OCR confidence",
                                    detail: formatScore(value))
        case .userAlwaysFlag(let pattern):
            return SignalDescriptor(symbol: "flag.fill", tint: .red,
                                    title: "Custom always-flag term",
                                    detail: pattern)
        case .userNeverFlag(let pattern):
            return SignalDescriptor(symbol: "flag.slash", tint: .gray,
                                    title: "Custom never-flag term",
                                    detail: pattern)
        case .suppressedByOverlap(let winner, let loser):
            // QW-5 — carry the loser's own category in the detail line so
            // the row doesn't read as the winner's category.
            return SignalDescriptor(symbol: "rectangle.stack.badge.minus", tint: .gray,
                                    title: "Suppressed by overlap",
                                    detail: loser.map {
                                        "\($0.rawValue), winner: \(winner.rawValue)"
                                    } ?? "winner: \(winner.rawValue)")
        case .contextPositiveDetail(let keywords):
            // WU-76 / [P4] — per-keyword breakdown. Keys come from the
            // closed gazetteer vocabulary (RR-31), so rendering them
            // verbatim is SAFE under §19. Contribution rendered as a
            // signed delta so the band-adjustment direction reads at a
            // glance.
            var parts: [String] = []
            for entry in keywords {
                let pct = Int((entry.contribution * 100).rounded())
                parts.append("'\(entry.keywordKey)' (+\(pct)%)")
            }
            return SignalDescriptor(
                symbol: "arrow.up.right.circle",
                tint: .green,
                title: "Positive context keywords",
                detail: parts.joined(separator: ", ")
            )
        case .contextNegativeDetail(let keywords):
            var negParts: [String] = []
            for entry in keywords {
                let pct = Int((entry.contribution * 100).rounded())
                negParts.append("'\(entry.keywordKey)' (-\(pct)%)")
            }
            return SignalDescriptor(
                symbol: "arrow.down.right.circle",
                tint: .orange,
                title: "Negative context keywords",
                detail: negParts.joined(separator: ", ")
            )
        case .negativeContextSuppressed(let keyword, let weight):
            // Gazetteer negative-context
            // suppression. The keyword comes from the closed gazetteer
            // vocabulary (not document content), so rendering it verbatim
            // is SAFE under §19, same as the detail variants above.
            return SignalDescriptor(
                symbol: "arrow.down.right.circle",
                tint: .orange,
                title: "Gazetteer negative context",
                detail: "'\(keyword)' (weight \(String(format: "%.2f", weight)))"
            )
        @unknown default:
            return SignalDescriptor(symbol: "circle.dotted", tint: .secondary,
                                    title: "Detector signal",
                                    detail: nil)
        }
    }


    /// WU-24: visibility lifted to `internal` so the score format is
    /// pinnable by tests. Unchanged formula.
    static func formatScore(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
