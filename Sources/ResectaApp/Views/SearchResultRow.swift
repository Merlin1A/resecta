import SwiftUI
import RedactionEngine

// Search-origin member of the unified row family. The shared skeleton
// (selection circle, content column, page indicator, a11y contract)
// lives in `FindingRow`; this file mounts the search-side accessories —
// leading confidence bar, source badge, applied indicator, term label,
// inline rationale disclosure — and keeps the pure display contracts
// (badges, tiers, tooltips, rationale summaries) other surfaces and
// tests consume.
//
// Bar grading: PII and detection rows grade on the shared absolute
// bands (`absoluteConfidenceTier`); OCR rows grade against `ocrFloor`
// (a live control); text/regex/Custom rows render the fixed-green
// literal-match band. The former `piiThreshold:` input is gone — it
// read the dormant `minimumPIIConfidence`, which no live UI can change
// since the per-run Confidence slider retired, so grading against it
// described a control that no longer exists.

struct SearchResultRow: View {
    @Binding var result: SearchResult
    var isCurrent: Bool = false
    /// Whether this result has been applied as a redaction region.
    var isApplied: Bool = false
    /// Show the search term label (multi-term mode, page grouping).
    var showTermLabel: Bool = false
    /// Active OCR confidence floor from `SearchState.minimumOCRConfidence`.
    /// Drives the confidence-bar tier on OCR rows. `Float` mirrors the
    /// underlying `SearchState` storage; converted to `Double` inside
    /// `confidenceTier(for:ocrFloor:)`.
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
        // SA-1 (D-71) micro-fix: signal-derived display inputs are
        // computed once per row build — `badgeView` / `confidenceTier`
        // / `confidenceBarTooltip` each re-scanned `rationale.signals`
        // for the same predicates on every body evaluation.
        let isCustomHit = Self.isCustomTermHit(result)
        let isRegexHit = Self.isRegexHit(result, searchMode: searchMode)
        let tier = Self.confidenceTier(
            for: result,
            ocrFloor: Double(ocrFloor),
            isCustomHit: isCustomHit
        )
        let barTooltip = Self.confidenceBarTooltip(
            for: result,
            isCustomHit: isCustomHit
        )
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
            // The tappable hit area is gesture-based (not an outer
            // Button) so the inner checkbox / chevron Buttons don't nest
            // inside another Button (UIKit hit-test ambiguity on iOS 17+
            // would otherwise dispatch outer + inner intent on the same
            // tap). PressHighlightModifier recreates the press dim.
            FindingRow(
                model: FindingRowModel(result: result),
                isSelected: Binding(
                    get: { result.isSelected },
                    set: { result.isSelected = $0 }
                ),
                leading: {
                    SearchRowConfidenceBar(tier: tier, tooltip: barTooltip)
                        .equatable()
                    // Applied-state indicator (12pt). Reserved slot
                    // between the confidence bar and the selection
                    // circle; empty when the row has not been applied.
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
                },
                badge: {
                    SearchRowSourceBadge(
                        result: result,
                        isCustomHit: isCustomHit,
                        isRegexHit: isRegexHit
                    )
                    .equatable()
                },
                trailing: {
                    // Term label for multi-term disambiguation
                    if showTermLabel {
                        Text(result.term)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .privacySensitive()
                    }

                    rationaleAccessory
                }
            )
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

    /// Rationale accessory toggles the inline
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

    /// Single-capsule renderer for the source badge. Branch order
    /// Custom → Regex → category/source. This two-parameter signature
    /// stays the public/test contract; it computes the signal flags and
    /// delegates to the flag-taking canonical implementation below
    /// (SA-1 — the row build precomputes the flags once and calls the
    /// canonical form directly).
    @ViewBuilder
    static func badgeView(for result: SearchResult, searchMode: SearchModeType) -> some View {
        badgeView(
            for: result,
            isCustomHit: Self.isCustomTermHit(result),
            isRegexHit: Self.isRegexHit(result, searchMode: searchMode)
        )
    }

    /// Canonical badge renderer over precomputed signal flags. The
    /// flags fully determine the branch together with `result` itself
    /// (`searchMode` participates only through `isRegexHit`).
    @ViewBuilder
    static func badgeView(
        for result: SearchResult,
        isCustomHit: Bool,
        isRegexHit: Bool
    ) -> some View {
        if isCustomHit {
            // User-defined always-flag term hit.
            Text("Custom")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, ResectaTokens.Spacing.xs)
                .padding(.vertical, 2)
                .background(ResectaTokens.SemanticColor.customTermBadge, in: Capsule())
                .accessibilityLabel("Custom term match")
        } else if isRegexHit {
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

    /// Within-floor band (15 percentage points) for OCR grading —
    /// confidence at or above `floor + bandwidth` is `.high`; within
    /// the band is `.medium`; below the floor is `.low`.
    static let confidenceBandwidth: Double = 0.15

    /// Shared absolute confidence bands for classifier findings —
    /// the same tiers the detection review rows use, so one confidence
    /// grammar covers both origins of the unified surface. ≥ 0.9 high,
    /// ≥ 0.7 medium, else low.
    static func absoluteConfidenceTier(_ confidence: Double) -> ConfidenceTier {
        if confidence >= 0.9 { return .high }
        if confidence >= 0.7 { return .medium }
        return .low
    }

    /// Mode-meaningful confidence-bar grading. Branch order
    /// mirrors the source badge's precedence: Custom → PII → OCR → text.
    /// PII rows grade on the shared absolute bands: the former
    /// `piiThreshold` input read `minimumPIIConfidence`, which is
    /// schema-compat state no live control can change since the per-run
    /// Confidence slider retired — grading against it described a
    /// control that no longer exists. This two-parameter signature
    /// stays the public/test contract and delegates to the flag-taking
    /// canonical form (SA-1).
    static func confidenceTier(
        for result: SearchResult,
        ocrFloor: Double
    ) -> ConfidenceTier {
        confidenceTier(
            for: result,
            ocrFloor: ocrFloor,
            isCustomHit: Self.isCustomTermHit(result)
        )
    }

    /// Canonical grading over the precomputed custom-hit flag, so the
    /// row build scans `rationale.signals` once for all three
    /// signal-derived display inputs.
    static func confidenceTier(
        for result: SearchResult,
        ocrFloor: Double,
        isCustomHit: Bool
    ) -> ConfidenceTier {
        if isCustomHit {
            return .high
        }
        if let piiConf = result.piiConfidence, result.piiCategory != nil {
            return absoluteConfidenceTier(piiConf)
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
    /// SAFE — mechanism description, no outcome promise. Public/test
    /// contract signature; delegates to the flag-taking form (SA-1).
    static func confidenceBarTooltip(for result: SearchResult) -> String {
        confidenceBarTooltip(for: result, isCustomHit: Self.isCustomTermHit(result))
    }

    /// Canonical tooltip over the precomputed custom-hit flag.
    static func confidenceBarTooltip(
        for result: SearchResult,
        isCustomHit: Bool
    ) -> String {
        if isCustomHit {
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
/// provided on `SearchResultRow`. SA-1 (D-71): press tracking rides a
/// never-completing long press (`minimumDuration: .infinity`) instead
/// of the former `DragGesture(minimumDistance: 0)` — the zero-distance
/// drag entered gesture arbitration against the List's pan on every
/// touch-down, a scroll-start tax paid by every row; a long-press
/// recognizer in the `.possible` state claims nothing, so the List pan
/// starts clean. `onPressingChanged` still fires true at touch-down
/// and false at lift / drag-away, so the dim visual is unchanged; the
/// row's tap gesture and the no-nested-Button contract are untouched.
/// (The infinite duration means `perform` never fires — the gesture
/// exists solely for its pressing edges.)
struct PressHighlightModifier: ViewModifier {
    @State private var isPressed: Bool = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.985 : 1.0)
            .opacity(isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .onLongPressGesture(minimumDuration: .infinity) {
            } onPressingChanged: { pressing in
                isPressed = pressing
            }
    }
}

// MARK: - SA-1 Equatable accessory wrappers
//
// The Equatable-value halves of the row extracted so `.equatable()`
// can skip their bodies on section-wide invalidations that leave the
// row's data unchanged (B-3: value content inside the equality,
// closures/bindings outside).

/// Leading-edge confidence bar. Mode-meaningful
/// (PII on the shared absolute bands, OCR against the live OCR floor,
/// text/regex/Custom against the literal-match constant); the bar's
/// help text on literal-match rows ships the resolved string
/// verbatim. Decorative for VoiceOver — confidence is exposed via
/// the source badge's accessibility label and the rationale sheet.
/// Tier + tooltip are precomputed by the row build.
struct SearchRowConfidenceBar: View, Equatable {
    let tier: SearchResultRow.ConfidenceTier
    let tooltip: String

    var body: some View {
        Rectangle()
            .fill(tier.color)
            .frame(width: 2)
            .help(tooltip)
            .accessibilityHidden(true)
    }
}

/// Source badge as an Equatable value view over the precomputed
/// signal flags; renders through the canonical
/// `SearchResultRow.badgeView(for:isCustomHit:isRegexHit:)` so the
/// badge branch logic stays in one place.
struct SearchRowSourceBadge: View, Equatable {
    let result: SearchResult
    let isCustomHit: Bool
    let isRegexHit: Bool

    var body: some View {
        SearchResultRow.badgeView(
            for: result,
            isCustomHit: isCustomHit,
            isRegexHit: isRegexHit
        )
    }
}
