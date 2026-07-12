import SwiftUI
import RedactionEngine

// Individual result row in the search results list.
//
// Adds a 2pt leading-edge confidence bar (mode-
// meaningful) and replaces the flat "OCR" capsule with a
// percent-bearing "OCR · N%" capsule. Bar grading: PII rows graded
// against `piiThreshold`, OCR rows graded against `ocrFloor`,
// text/regex/Custom rows render the fixed-green literal-match band
// (tooltip uses the "Literal match — strength matches
// the input text." verbatim). Grading lives on a static helper so the
// contract is testable without a SwiftUI host.

struct SearchResultRow: View {
    @Binding var result: SearchResult
    var isCurrent: Bool = false
    /// Whether this result has been applied as a redaction region.
    var isApplied: Bool = false
    /// Show the search term label (multi-term mode, page grouping).
    var showTermLabel: Bool = false
    /// Active PII confidence threshold from `SearchState.minimumPIIConfidence`.
    /// Drives the confidence-bar tier on PII rows.
    var piiThreshold: Double = 0.0
    /// Active OCR confidence floor from `SearchState.minimumOCRConfidence`.
    /// Drives the confidence-bar tier on OCR rows. `Float` mirrors the
    /// underlying `SearchState` storage; converted to `Double` inside
    /// `confidenceTier(for:piiThreshold:ocrFloor:)`.
    var ocrFloor: Float = 0.0
    /// Active search mode from `SearchState.searchModeType`. Gates
    /// the Regex source badge — `.regex` mode + `.regexPattern` rationale
    /// signal renders the indigo Regex capsule (the indigo
    /// fallback over the original teal that visually clashed with OCR).
    /// PII Scan results often carry `.regexPattern` rationale signals
    /// internally; the mode gate prevents the Regex capsule from
    /// rendering on PII rows. Defaults to `.text` so existing callers
    /// that don't thread the mode keep the Text/PII branch behavior.
    var searchMode: SearchModeType = .text
    var onNavigate: () -> Void
    /// Emit a rationale request upward instead of holding the
    /// presenter state locally. The parent (`SearchAndRedactSheet`)
    /// converts this into `activeModal = .rowRationale(rowID:, composed:)`,
    /// routing through the same `.sheet(item:)` slot every other modal
    /// uses. Default is a no-op so prior callers and previews compile.
    var onShowRationale: () -> Void = {}

    /// Per-row toggle for the inline rationale
    /// summary. Default collapsed; the trailing chevron flips it.
    /// Local state so each row's expansion is independent. Hidden
    /// entirely when `result.rationale == nil` (non-PII rows).
    @State private var isRationaleExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
            // The outer Button was replaced with a gesture-based
            // hit area so the inner checkbox / chevron Buttons no longer
            // nest inside another Button (UIKit hit-test ambiguity on
            // iOS 17+ would otherwise dispatch outer + inner intent on
            // the same tap). The PressHighlightModifier recreates the
            // press dim that the outer Button previously provided.
            HStack(spacing: 0) {
                // Leading-edge confidence bar. Color graded
                // against the active PII threshold / OCR floor; text/regex/Custom
                // rows render the fixed-green literal-match band.
                confidenceBar

                HStack(spacing: ResectaTokens.Spacing.sm) {
                    // Applied-state indicator (12pt). Reserved slot
                    // between the confidence bar and the selection
                    // checkbox; empty when the row has not been applied.
                    Group {
                        if isApplied {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else {
                            EmptyView()
                        }
                    }
                    .frame(width: 12)

                    // Selection toggle
                    Button {
                        result.isSelected.toggle()
                    } label: {
                        Image(systemName: result.isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(result.isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 28)

                    // Source badge
                    sourceBadge

                    // Text content
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.matchedText)
                            .font(.subheadline.monospaced())
                            .lineLimit(1)
                            .privacySensitive()  // Matched text is sensitive

                        Text(result.contextSnippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .privacySensitive()  // Context is sensitive
                    }

                    Spacer()

                    // Term label for multi-term disambiguation
                    if showTermLabel {
                        Text(result.term)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .privacySensitive()
                    }

                    rationaleAccessory

                    // Page indicator
                    Text("p.\(result.pageIndex + 1)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, ResectaTokens.Spacing.xs)
            }
            .contentShape(Rectangle())
            .onTapGesture { onNavigate() }
            .modifier(PressHighlightModifier())

            // Inline rationale summary on PII rows. Renders only
            // when the user expands via the trailing chevron — default
            // collapsed so the 4-element invariant (matched text +
            // context snippet + source badge + page indicator) holds.
            if isRationaleExpanded, let rationale = result.rationale {
                inlineRationaleSummary(for: rationale)
            }
        }
        .listRowBackground(isCurrent ? ResectaTokens.BrandTeal.tint.opacity(0.12) : nil)
        // Announce page number only, NEVER matched text
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Search match, page \(result.pageIndex + 1)")
        .accessibilityAddTraits(result.isSelected ? .isSelected : [])
        // Immediate VoiceOver feedback on selection toggle
        .onChange(of: result.isSelected) { _, isSelected in
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: isSelected ? "Selected" : "Deselected"
                )
            }
        }
    }

    /// Rationale accessory now toggles the inline
    /// expansion (was: info.circle opening MatchRationaleSheet directly).
    /// The full-detail sheet path remains reachable via the "View
    /// details" button inside the inline expansion. Per the long-
    /// press density cap the row keeps a single tap-target affordance
    /// for rationale (chevron); the contextMenu's "Why this match?"
    /// path opens the broader `ReverseRationalePopover` and is
    /// unchanged.
    @ViewBuilder
    private var rationaleAccessory: some View {
        if result.rationale != nil {
            Button {
                isRationaleExpanded.toggle()
            } label: {
                Image(systemName: isRationaleExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRationaleExpanded
                                ? "Collapse rationale"
                                : "Expand rationale")
            .accessibilityHint("Reveals a short summary of the detector's match signals")
        }
    }

    /// Inline rationale summary rendered below the
    /// main row HStack when `isRationaleExpanded == true`. Single-line
    /// "Reason: <signals> (<score>)." —
    /// mechanism-only nouns (regex / context / validator / name /
    /// doctype / threshold / ocr / custom). The trailing "View details"
    /// button preserves the existing MatchRationaleSheet path.
    @ViewBuilder
    private func inlineRationaleSummary(for rationale: MatchRationale) -> some View {
        HStack(spacing: ResectaTokens.Spacing.xs) {
            Text(Self.inlineRationaleSummaryString(for: rationale))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                onShowRationale()
            } label: {
                Text("Details")
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View full rationale")
            .accessibilityHint("Opens the detector's full evidence breakdown")
        }
        .padding(.leading, ResectaTokens.Spacing.lg)
        .padding(.trailing, ResectaTokens.Spacing.sm)
        .padding(.bottom, ResectaTokens.Spacing.xxs)
    }

    /// Leading-edge confidence bar. Mode-meaningful
    /// (PII against `piiThreshold`, OCR against `ocrFloor`,
    /// text/regex/Custom against the literal-match constant); the bar's
    /// help text on literal-match rows ships the resolved string
    /// verbatim. Decorative for VoiceOver — confidence is exposed via
    /// the source badge's accessibility label and the rationale sheet.
    private var confidenceBar: some View {
        Rectangle()
            .fill(
                Self.confidenceTier(
                    for: result,
                    piiThreshold: piiThreshold,
                    ocrFloor: Double(ocrFloor)
                ).color
            )
            .frame(width: 2)
            .help(Self.confidenceBarTooltip(for: result))
            .accessibilityHidden(true)
    }

    private var sourceBadge: some View {
        Self.badgeView(for: result, searchMode: searchMode)
    }

    /// Single-capsule renderer for the source badge. Branch order
    /// Custom → Regex → category/source.
    @ViewBuilder
    static func badgeView(for result: SearchResult, searchMode: SearchModeType) -> some View {
        if Self.isCustomTermHit(result) {
            // User-defined always-flag term hit.
            Text("Custom")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, ResectaTokens.Spacing.xs)
                .padding(.vertical, 2)
                .background(ResectaTokens.SemanticColor.customTermBadge, in: Capsule())
                .accessibilityLabel("Custom term match")
        } else if Self.isRegexHit(result, searchMode: searchMode) {
            // Regex-mode hit with a `.regexPattern` rationale
            // signal. Mode-gated indigo capsule.
            Text(Self.regexCapsuleText(for: result))
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, ResectaTokens.Spacing.xs)
                .padding(.vertical, 2)
                .background(ResectaTokens.SemanticColor.regexBadge, in: Capsule())
                .accessibilityLabel("Regex match")
        } else if let category = result.piiCategory {
            // PII category badge with category-specific color.
            Self.piiBadgeView(for: result, category: category)
        } else {
            // Standard source badge for text/regex/multi-term searches.
            switch result.source {
            case .textLayer:
                Text("Text")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, ResectaTokens.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(Color(uiColor: .systemGreen), in: Capsule())
            case .ocr(let confidence):
                // Percent-bearing capsule replaces the flat "OCR" label.
                Text(Self.ocrCapsuleLabel(confidence: confidence))
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, ResectaTokens.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(Color(uiColor: .systemTeal), in: Capsule())
                    .accessibilityLabel("OCR, \(Int(confidence * 100))% confidence")
            }
        }
    }

    /// Static variant of the PII category badge. Behavior identical
    /// to the equivalent instance method — extracted to `static` so the
    /// helper can be invoked from `Self.badgeView(...)` without capturing
    /// the surrounding row.
    @ViewBuilder
    static func piiBadgeView(for result: SearchResult, category: PIICategory) -> some View {
        HStack(spacing: 2) {
            Image(systemName: category.symbolName)
                .font(.caption2)
            Text(category.rawValue)
                .font(.caption2.bold())
            // Show OCR source indicator when PII was detected via OCR.
            // The percent is encoded by the leading-edge confidence bar
            // and remains in the badge's VoiceOver label.
            if case .ocr = result.source {
                Text("OCR")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, ResectaTokens.Spacing.xs)
        .padding(.vertical, 2)
        .background(Self.categoryColor(category), in: Capsule())
        .accessibilityLabel(Self.piiBadgeAccessibilityLabel(for: result, category: category))
    }

    /// Static accessibility-label helper, mirrors the prior
    /// instance method. The OCR source indicator and PII confidence
    /// are read off the passed `result` so any contribution renders
    /// its own confidence inside the stacked-badge HStack.
    static func piiBadgeAccessibilityLabel(
        for result: SearchResult,
        category: PIICategory
    ) -> String {
        let conf = Int((result.piiConfidence ?? 0) * 100)
        let source = result.source == .textLayer ? "" : ", OCR source"
        return "\(category.rawValue), \(conf)% confidence\(source)"
    }

    static func isCustomTermHit(_ result: SearchResult) -> Bool {
        guard let signals = result.rationale?.signals else { return false }
        return signals.contains { signal in
            if case .userAlwaysFlag = signal { return true }
            return false
        }
    }

    /// Regex-mode hit predicate. Returns true when the user is in
    /// `.regex` mode AND the rationale's signal list contains
    /// `.regexPattern(...)`. Both conjuncts are load-bearing — PII Scan
    /// emissions often carry `.regexPattern` internally (the PII detector
    /// uses regex sub-passes), so the mode gate keeps the indigo Regex
    /// capsule from rendering on PII rows. Pure-function contract;
    /// testable without a SwiftUI host.
    static func isRegexHit(_ result: SearchResult, searchMode: SearchModeType) -> Bool {
        guard searchMode == .regex else { return false }
        guard let signals = result.rationale?.signals else { return false }
        return signals.contains { signal in
            if case .regexPattern = signal { return true }
            return false
        }
    }

    /// Regex capsule label. Renders `"Regex: <name>"` when the
    /// `.regexPattern(name)` signal carries a short label (≤ 20 chars
    /// — the saved-regex menu enforces no upper bound on names but
    /// labels longer than ~20 chars overflow the capsule width). Ad-hoc
    /// regex hits emit `.regexPattern(pattern)` where `pattern` is the
    /// raw regex source — long with metacharacters; in that case fall
    /// back to the unlabeled `"Regex"` form. Pure-function helper;
    /// classified SAFE (UI label).
    static func regexCapsuleText(for result: SearchResult) -> String {
        guard let signals = result.rationale?.signals else { return "Regex" }
        for signal in signals {
            if case .regexPattern(let name) = signal {
                if !name.isEmpty && name.count <= 20 {
                    return "Regex: \(name)"
                }
                break
            }
        }
        return "Regex"
    }

    /// Category-specific badge colors for visual differentiation.
    static func categoryColor(_ category: PIICategory) -> Color {
        switch category {
        case .ssn: Color(uiColor: .systemRed)
        case .creditCard: Color(uiColor: .systemOrange)
        case .email: Color(uiColor: .systemBlue)
        case .phone: Color(uiColor: .systemTeal)
        case .address: Color(uiColor: .systemBrown)
        case .ein: Color(uiColor: .systemIndigo)
        case .itin: Color(uiColor: .systemIndigo)
        case .driversLicense: Color(uiColor: .systemPurple)
        case .name: Color(uiColor: .systemMint)
        case .dateOfBirth: Color(uiColor: .systemPink)
        case .passport: Color(uiColor: .systemCyan)
        case .medicalRecord: Color(uiColor: .systemRed).opacity(0.8)
        case .npi: Color(uiColor: .systemGreen)
        case .dea: Color(uiColor: .systemRed).opacity(0.8)
        case .account: Color(uiColor: .systemYellow)
        // UIColor.system* for increased-contrast compatibility.
        case .routingNumber: Color(uiColor: .systemOrange).opacity(0.8)
        case .licensePlate: Color(uiColor: .systemTeal).opacity(0.8)
        }
    }
}

// MARK: - Confidence-Bar Contract

extension SearchResultRow {
    /// Three-tier classification driving the confidence-bar color.
    /// Reuses existing `ResectaTokens.SemanticColor.confidenceHigh/Medium/Low` —
    /// no new tokens introduced.
    enum ConfidenceTier: Equatable {
        case high
        case medium
        case low

        var color: Color {
            switch self {
            case .high: return ResectaTokens.SemanticColor.confidenceHigh
            case .medium: return ResectaTokens.SemanticColor.confidenceMedium
            case .low: return ResectaTokens.SemanticColor.confidenceLow
            }
        }
    }

    /// Within-threshold band (15 percentage points) — confidence at or
    /// above `threshold + bandwidth` is `.high`; within the band is
    /// `.medium`; below threshold is `.low` (defensive — pre-filtered
    /// rows shouldn't reach this branch).
    static let confidenceBandwidth: Double = 0.15

    /// Mode-meaningful confidence-bar grading. Branch order
    /// mirrors `sourceBadge`'s precedence: Custom → PII → OCR → text.
    static func confidenceTier(
        for result: SearchResult,
        piiThreshold: Double,
        ocrFloor: Double
    ) -> ConfidenceTier {
        if Self.isCustomTermHit(result) {
            return .high
        }
        if let piiConf = result.piiConfidence, result.piiCategory != nil {
            if piiConf >= piiThreshold + Self.confidenceBandwidth { return .high }
            if piiConf >= piiThreshold { return .medium }
            return .low
        }
        if case .ocr(let confidence) = result.source {
            let conf = Double(confidence)
            if conf >= ocrFloor + Self.confidenceBandwidth { return .high }
            if conf >= ocrFloor { return .medium }
            return .low
        }
        // .textLayer + no piiCategory + not Custom → literal text/regex match.
        return .high
    }

    /// Text/regex/Custom rows surface the
    /// literal-match tooltip on the bar; PII/OCR rows return empty
    /// (their confidence is rendered inline on the source badge).
    /// SAFE — mechanism description, no outcome promise.
    static func confidenceBarTooltip(for result: SearchResult) -> String {
        if Self.isCustomTermHit(result) {
            return "Literal match — strength matches the input text."
        }
        if result.piiCategory == nil, result.source == .textLayer {
            return "Literal match — strength matches the input text."
        }
        return ""
    }

    /// Capsule label for OCR
    /// rows. The percent the user used to see here is encoded by the
    /// leading-edge confidence bar; VoiceOver still speaks the percent
    /// via the badge's accessibility label.
    static func ocrCapsuleLabel(confidence: Float) -> String {
        "OCR"
    }
}

// MARK: - Inline Rationale Summary

extension SearchResultRow {
    /// Short mechanism-noun label per `MatchRationale.Signal` case.
    /// The labels feed `inlineRationaleSummaryString(for:)`'s `+`-joined
    /// summary. Each label is mechanism-only — describes
    /// what the detector matched, not what the user should do. Returns
    /// `nil` for cases that don't contribute to the summary (e.g.
    /// `userNeverFlag`, `suppressedByOverlap` are suppression signals,
    /// not match-strength evidence).
    static func signalShortLabel(for signal: MatchRationale.Signal) -> String? {
        switch signal {
        case .regexPattern:
            return "regex"
        case .structuralValidator:
            return "validator"
        case .contextPositive, .contextNegative:
            return "context"
        case .bloomSurnameHit, .bloomGivenHit, .bloomFuzzySurnameHit:
            return "name"
        case .doctypeGate:
            return "doctype"
        case .presetThresholdPass:
            return "threshold"
        case .ocrConfidence:
            return "ocr"
        case .userAlwaysFlag:
            return "custom"
        case .userNeverFlag, .suppressedByOverlap:
            return nil
        case .contextPositiveDetail, .contextNegativeDetail:
            // Fold the detail variants into the existing
            // "context" bucket so the inline summary stays a 1-word
            // mechanism noun. The detail keywords surface in the
            // expanded sheets (MatchRationaleSheet, RegionRationaleSheet)
            // not in this compact row summary.
            return "context"
        case .negativeContextSuppressed:
            // Gazetteer suppression
            // folds into the same "context" mechanism bucket; the
            // keyword + weight surface in the expanded sheets.
            return "context"
        }
    }

    /// Inline rationale summary line for the row-expansion area.
    /// Format: `"Reason: <signals> (detector score <score>)."` —
    /// signals join with `+` (deduped, preserving first-encounter order),
    /// score formats to two decimal places. The number carries the
    /// "detector score" noun so it can't be misread as the row's match
    /// confidence — they are different quantities. The summary stays
    /// mechanism-only — never includes outcome verbs
    /// ("flagged", "redacted") or imperatives ("redact this"). The
    /// "Reason:" prefix is itself SAFE.
    static func inlineRationaleSummaryString(for rationale: MatchRationale) -> String {
        var labels: [String] = []
        var seen = Set<String>()
        for signal in rationale.signals {
            guard let label = signalShortLabel(for: signal) else { continue }
            guard !seen.contains(label) else { continue }
            labels.append(label)
            seen.insert(label)
        }
        let scoreString = String(format: "%.2f", rationale.finalScore)
        if labels.isEmpty {
            return "Reason: detector score \(scoreString)."
        }
        return "Reason: \(labels.joined(separator: "+")) (detector score \(scoreString))."
    }
}

/// Recreates the press dim that the outer Button previously
/// provided on `SearchResultRow`. A `DragGesture(minimumDistance: 0)`
/// tracks the touch-down/touch-up edges so SwiftUI fires the scale and
/// opacity changes synchronously with the tap-gesture recognizer.
struct PressHighlightModifier: ViewModifier {
    @State private var isPressed: Bool = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.985 : 1.0)
            .opacity(isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed { isPressed = true }
                    }
                    .onEnded { _ in isPressed = false }
            )
    }
}
