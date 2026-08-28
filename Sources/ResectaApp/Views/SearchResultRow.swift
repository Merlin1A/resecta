import SwiftUI
import RedactionEngine

// Search-origin result row. Context-first — the row's one text block
// is the engine's context window with the match itself set
// semibold-monospaced on a soft brand-teal wash inside proportional
// context (the engine windows the text so the match can never
// truncate; `SearchResult.matchRangeInSnippet` locates it). A small
// meta line above it carries the source badge and the page label only
// when the visible list is not sectioned by page. Confidence is not
// spelled out on the row — no tier word, no rationale line; the
// leading bar stays as the family's quiet cue and the spoken tier
// stays in the merged a11y label for parity with it, while the
// quantities themselves live in `MatchRationaleSheet`, reached through
// the Details button the chevron expansion reveals beneath the full
// window. The leading confidence bar, the applied marker, and the 46-pt
// selection circle keep the shared-family idiom of `FindingRow`, which
// this row no longer mounts: the scan-review origin still renders
// through `FindingRow` unchanged — that surface is frozen this release.
// The pure display contracts (badges, tiers, tooltips, rationale
// summaries) other surfaces and tests consume stay in this file.
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
    /// The adaptive page label. The section passes `true` only when
    /// the visible list is NOT sectioned by page (multi-term's by-term
    /// grouping today); under page sections the header carries the
    /// page and the row shows no `p.N`.
    var showsPageLabel: Bool = false
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

    /// Per-row toggle for the expanded state: the full context window
    /// un-clamped plus the inline rationale line when the result
    /// carries one. The name predates the context expansion and stays
    /// — renaming a private state var is churn.
    @State private var isRationaleExpanded: Bool = false

    /// The collapsed clamp grows from XXXL up so a long match the
    /// 44-character lead-in pushes past line 2 at large type still
    /// shows whole in the collapsed row.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Width of the applied-marker slot between the bar and the circle.
    static let appliedIndicatorWidth: CGFloat = 12

    /// Leading inset of the content column (meta line + window) from the
    /// row's leading edge: bar + the applied slot (present only on an
    /// applied row — the unapplied slot is `EmptyView`, zero width, the
    /// chassis idiom) + the chassis inset + the selection circle + the
    /// circle→content gap. The expanded rationale line aligns to it.
    static func contentColumnLeadingInset(isApplied: Bool) -> CGFloat {
        SearchRowConfidenceBar.width
            + (isApplied ? appliedIndicatorWidth : 0)
            + ResectaTokens.Spacing.xs
            + ResectaTokens.TouchTarget.minimum
            + ResectaTokens.Spacing.sm
    }

    var body: some View {
        // Signal-derived display inputs are computed once per row
        // build — `badgeView` / `confidenceTier` /
        // `confidenceBarTooltip` each re-scanned `rationale.signals`
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
        let showsTier = Self.showsTierWord(for: result)
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
            // The tappable hit area is gesture-based (not an outer
            // Button) so the inner selection / chevron Buttons don't nest
            // inside another Button (UIKit hit-test ambiguity on iOS 17+
            // would otherwise dispatch outer + inner intent on the same
            // tap). PressHighlightModifier recreates the press dim.
            HStack(spacing: 0) {
                SearchRowConfidenceBar(tier: tier, tooltip: barTooltip)
                    .equatable()
                // Applied-state indicator (12pt). Reserved slot between
                // the confidence bar and the selection circle; empty
                // when the row has not been applied. Decorative — the
                // a11y contract names the page, never the marker.
                Group {
                    if isApplied {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        EmptyView()
                    }
                }
                .frame(width: Self.appliedIndicatorWidth)
                .accessibilityHidden(true)

                HStack(alignment: .top, spacing: 0) {
                    HStack(spacing: ResectaTokens.Spacing.sm) {
                        selectionCircle
                        VStack(alignment: .leading, spacing: 2) {
                            metaLine(
                                isCustomHit: isCustomHit,
                                isRegexHit: isRegexHit,
                                tier: tier
                            )
                            // The one text block: proportional context,
                            // the match run mono on the wash. Collapsed =
                            // two lines; expanded = the whole window.
                            Text(Self.attributedSnippet(
                                result.contextSnippet,
                                matchRange: result.matchRangeInSnippet,
                                matchedText: result.matchedText
                            ))
                            .lineLimit(isRationaleExpanded
                                       ? nil
                                       : Self.collapsedLineLimit(for: dynamicTypeSize))
                            .privacySensitive()
                        }
                    }
                    .padding(.leading, ResectaTokens.Spacing.xs)
                    // ONE merged element that names the page (and the
                    // spoken tier where the row is graded — the bar's
                    // non-visual twin) — never the matched text, never
                    // the window.
                    // The `.ignore` merge hides the inner selection
                    // circle; the named action keeps non-visual
                    // selection first-class.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.accessibilityLabel(
                        for: result, tier: tier, showsTier: showsTier
                    ))
                    .accessibilityAddTraits(result.isSelected ? .isSelected : [])
                    .accessibilityAction(named: "Toggle selection") {
                        result.isSelected.toggle()
                    }

                    // The chevron sits OUTSIDE the merge so it stays a
                    // reachable control with its own label (VoiceOver,
                    // XCUI); top-aligned so its 46-pt frame rides beside
                    // the meta line without lifting the row's height.
                    rationaleAccessory
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onNavigate() }
            .modifier(PressHighlightModifier())

            // Details line (PII / Custom rows carry a rationale), in the
            // expanded state only, beneath the un-clamped window — the
            // row's one path into `MatchRationaleSheet` (the former
            // "Reason:" one-liner is gone; the sheet carries it).
            if isRationaleExpanded, result.rationale != nil {
                detailsLine
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

    /// The one selection circle the family shares — the `FindingRow`
    /// chassis idiom verbatim: a 46-pt floor on BOTH axes framed on
    /// the whole button plus `contentShape`, haptic on toggle.
    private var selectionCircle: some View {
        Button {
            result.isSelected.toggle()
        } label: {
            Image(systemName: result.isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(result.isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .frame(
            width: ResectaTokens.TouchTarget.minimum,
            height: ResectaTokens.TouchTarget.minimum
        )
        .contentShape(Rectangle())
        .sensoryFeedback(.selection, trigger: result.isSelected)
    }

    /// Meta line: source badge · adaptive page label · spacer · term
    /// label (multi-term under page grouping). The tier word that used
    /// to follow the badge is retired — confidence is not spelled out
    /// on the row.
    private func metaLine(
        isCustomHit: Bool,
        isRegexHit: Bool,
        tier: ConfidenceTier
    ) -> some View {
        HStack(spacing: ResectaTokens.Spacing.xs) {
            SearchRowSourceBadge(
                result: result,
                isCustomHit: isCustomHit,
                isRegexHit: isRegexHit,
                tier: tier
            )
            .equatable()
            if showsPageLabel {
                Text("p.\(result.pageIndex + 1)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            // Term label for multi-term disambiguation
            if showTermLabel {
                Text(result.term)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .privacySensitive()
            }
        }
    }

    /// The expand/collapse control: always visible — every row has
    /// context to reveal — and outside the row's a11y merge so it
    /// stays a reachable control. Id FROZEN
    /// (`rationaleDisclosureButton`). Expanded = the full context window
    /// un-clamped + the "Details" button into `MatchRationaleSheet`
    /// (rows that carry a rationale; the one-line rationale summary
    /// that used to sit beside it is retired). Per the long-press
    /// density cap the row keeps a single tap-target affordance for
    /// rationale (this chevron); the contextMenu's "Why this match?"
    /// path opens the broader `ReverseRationalePopover` and is unchanged.
    private var rationaleAccessory: some View {
        Button {
            isRationaleExpanded.toggle()
        } label: {
            Image(systemName: isRationaleExpanded ? "chevron.up" : "chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
                // Floored to the HIG minimum (46-pt layout frame).
                // Same contentShape idiom.
                .frame(
                    width: ResectaTokens.TouchTarget.minimum,
                    height: ResectaTokens.TouchTarget.minimum
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRationaleExpanded ? "Show less" : "Show full context")
        .accessibilityHint(isRationaleExpanded
                           ? "Collapses the surrounding text back to its short form"
                           : "Expands the match's surrounding text")
        .accessibilityIdentifier("rationaleDisclosureButton")
    }

    /// The Details line rendered below the un-clamped window when the
    /// row is expanded: a single trailing "Details" button into
    /// `MatchRationaleSheet`, where the detector's signals, the
    /// scores, and the match confidence live. It keeps the position
    /// the retired "Reason:" summary's button had — leading inset to
    /// the content column, trailing-aligned — so the expansion reads
    /// as the window plus one action; now that it stands alone it
    /// carries the 46-pt layout floor the text beside it used to
    /// excuse.
    private var detailsLine: some View {
        HStack(spacing: ResectaTokens.Spacing.xs) {
            Spacer()
            Button {
                onShowRationale()
            } label: {
                Text("Details")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .frame(minHeight: ResectaTokens.TouchTarget.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View full rationale")
            .accessibilityHint("Opens the detector's full evidence breakdown")
        }
        .padding(.leading, Self.contentColumnLeadingInset(isApplied: isApplied))
        .padding(.trailing, ResectaTokens.Spacing.sm)
        .padding(.bottom, ResectaTokens.Spacing.xxs)
    }

    /// Single-capsule renderer for the source badge. Branch order
    /// Custom → Regex → category/source. This two-parameter signature
    /// stays the public/test contract; it computes the signal flags and
    /// delegates to the flag-taking canonical implementation below —
    /// the row build precomputes the flags once and calls the
    /// canonical form directly.
    @ViewBuilder
    static func badgeView(
        for result: SearchResult,
        searchMode: SearchModeType,
        ocrFloor: Float = 0.0
    ) -> some View {
        let isCustomHit = Self.isCustomTermHit(result)
        badgeView(
            for: result,
            isCustomHit: isCustomHit,
            isRegexHit: Self.isRegexHit(result, searchMode: searchMode),
            tier: Self.confidenceTier(
                for: result,
                ocrFloor: Double(ocrFloor),
                isCustomHit: isCustomHit
            )
        )
    }

    /// Canonical badge renderer over precomputed signal flags. The
    /// flags fully determine the branch together with `result` itself
    /// (`searchMode` participates only through `isRegexHit`). `tier` is
    /// the row's already-computed floor-relative tier — only the OCR
    /// leg of the standard source-badge branch reads it, for the
    /// capsule's accessibility label.
    @ViewBuilder
    static func badgeView(
        for result: SearchResult,
        isCustomHit: Bool,
        isRegexHit: Bool,
        tier: ConfidenceTier
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
                // The capsule itself renders the flat "OCR" label — see
                // `ocrCapsuleLabel` (this comment used to claim the
                // capsule was "percent-bearing", which was already
                // false — it always rendered flat "OCR"). The
                // confidence tier descriptor surfaces via the
                // accessibility label below and via color on the
                // leading-edge confidence bar, not via capsule text.
                Text(Self.ocrCapsuleLabel(confidence: confidence))
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, ResectaTokens.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(Color(uiColor: .systemTeal), in: Capsule())
                    .accessibilityLabel(Self.ocrCapsuleAccessibilityLabel(tier: tier))
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
        let piiConf = result.piiConfidence ?? 0
        let source = result.source == .textLayer ? "" : ", OCR source"
        return "\(category.rawValue), \(absoluteConfidenceTier(piiConf).descriptor)\(source)"
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
    /// `nonisolated`: under the SE-0466 MainActor-default flip this pure
    /// value type (no MainActor state) would otherwise become
    /// MainActor-isolated, which breaks `RegionMetadata`'s nonisolated
    /// init reading `.descriptor` off `absoluteConfidenceTier`'s
    /// result. Mirrors `ResectaTokens.SemanticColor`'s same-rationale pin.
    nonisolated enum ConfidenceTier: Equatable {
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

        /// Qualitative descriptor replacing the retired "N% confidence"
        /// copy. Lowercase, for mid-sentence / spoken use (e.g. "Social
        /// Security Number, high confidence").
        /// Thresholds live ONLY on `absoluteConfidenceTier` /
        /// `confidenceTier(for:ocrFloor:)` — this is a pure label over an
        /// already-computed tier, never a second threshold source.
        var descriptor: String {
            switch self {
            case .high: return "high confidence"
            case .medium: return "medium confidence"
            case .low: return "low confidence"
            }
        }

        /// Sentence-position form: first letter capitalized, for a
        /// standalone visible line (e.g. detection-row secondary text)
        /// or a sentence-final accessibility clause (e.g. "Page 2. High
        /// confidence.").
        var descriptorLabel: String {
            switch self {
            case .high: return "High confidence"
            case .medium: return "Medium confidence"
            case .low: return "Low confidence"
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
    /// `nonisolated`: under the SE-0466 MainActor-default flip this pure
    /// function would otherwise become MainActor-isolated, which breaks
    /// `RegionMetadata`'s nonisolated init, the one other non-View
    /// call site.
    nonisolated static func absoluteConfidenceTier(_ confidence: Double) -> ConfidenceTier {
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
    /// canonical form.
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
    /// contract signature; delegates to the flag-taking form.
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

    /// OCR source-badge accessibility label. Takes the row's
    /// already-computed floor-relative `tier` (not a raw confidence) so
    /// the spoken label matches what the leading-edge confidence bar
    /// shows, and so no percent threshold is duplicated here.
    static func ocrCapsuleAccessibilityLabel(tier: ConfidenceTier) -> String {
        "OCR, \(tier.descriptor)"
    }
}

// MARK: - Context-first row contracts

extension SearchResultRow {
    /// True where the tier is graded: PII rows (absolute bands) and
    /// OCR-source rows (floor-relative). Literal text / regex / custom
    /// text-layer hits grade `.high` by construction, so a spoken tier
    /// would be noise; their bar still renders the literal-match
    /// green. The meta line no longer renders a tier word, so this
    /// predicate gates ONLY the spoken tier in the merged a11y label
    /// (the bar's non-visual twin); the name is kept for the pins that
    /// reference it.
    nonisolated static func showsTierWord(for result: SearchResult) -> Bool {
        if result.piiConfidence != nil { return true }
        if case .ocr = result.source { return true }
        return false
    }

    /// The merged row element's spoken label: the family adapter's
    /// page-only string (never matched text, never the window) plus
    /// the tier descriptor where the row is graded (spoken for parity
    /// with the bar, no longer mirrored by a visible word).
    static func accessibilityLabel(
        for result: SearchResult,
        tier: ConfidenceTier,
        showsTier: Bool
    ) -> String {
        let base = FindingRowModel(result: result).accessibilityDescription
        return showsTier ? "\(base), \(tier.descriptor)" : base
    }

    /// The collapsed window's line clamp: two lines through XXL, three
    /// from XXXL up (the same threshold the compact strip's counter
    /// uses) so a long match the lead-in pushes past line 2 at large
    /// type still shows whole while collapsed.
    nonisolated static func collapsedLineLimit(for size: DynamicTypeSize) -> Int {
        size >= .xxxLarge ? 3 : 2
    }

    /// Brand-teal wash opacity under the match run. Tuned on-sim in
    /// both appearances.
    nonisolated static let matchWashOpacity: Double = 0.16

    /// The row's one text block: the context window
    /// in proportional secondary text with the match run set
    /// semibold-monospaced in primary on the brand-teal wash. Mono stays
    /// the exclusive signature of detected content. `matchRange` is the
    /// engine's Character range inside `snippet`; nil (hand-built
    /// results) falls back to the first verbatim occurrence of
    /// `matchedText`; with no occurrence the plain base returns. Both
    /// runs use text styles so they scale together under Dynamic Type.
    nonisolated static func attributedSnippet(
        _ snippet: String,
        matchRange: Range<Int>?,
        matchedText: String
    ) -> AttributedString {
        var attributed = AttributedString(snippet)
        attributed.font = .footnote
        attributed.foregroundColor = .secondary
        guard let run = matchRun(in: attributed, matchRange: matchRange, matchedText: matchedText) else {
            return attributed
        }
        attributed[run].font = .footnote.monospaced().weight(.semibold)
        attributed[run].foregroundColor = .primary
        attributed[run].backgroundColor = ResectaTokens.BrandTeal.tint.opacity(matchWashOpacity)
        return attributed
    }

    /// The attributed range of the match run: the engine's Character
    /// range when it is in bounds, else the first verbatim occurrence.
    private nonisolated static func matchRun(
        in attributed: AttributedString,
        matchRange: Range<Int>?,
        matchedText: String
    ) -> Range<AttributedString.Index>? {
        let characters = attributed.characters
        if let matchRange,
           matchRange.lowerBound >= 0,
           !matchRange.isEmpty,
           matchRange.upperBound <= characters.count {
            let lower = characters.index(characters.startIndex, offsetBy: matchRange.lowerBound)
            let upper = characters.index(lower, offsetBy: matchRange.count)
            return lower..<upper
        }
        guard !matchedText.isEmpty else { return nil }
        return attributed.range(of: matchedText)
    }
}

// MARK: - Rationale Summary (the MatchRationaleSheet Signals footer)

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

    /// One-line rationale summary. It renders as the Signals footer of
    /// `MatchRationaleSheet` (it used to sit in the row-expansion
    /// area). Format: `"Reason: <signals> (detector
    /// score <score>)."` —
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
/// provided on `SearchResultRow`. Press tracking rides a
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

// MARK: - Equatable accessory wrappers
//
// The Equatable-value halves of the row extracted so `.equatable()`
// can skip their bodies on section-wide invalidations that leave the
// row's data unchanged (value content inside the equality,
// closures/bindings outside).

/// Leading-edge confidence bar. Mode-meaningful
/// (PII on the shared absolute bands, OCR against the live OCR floor,
/// text/regex/Custom against the literal-match constant); the bar's
/// help text on literal-match rows ships the resolved string
/// verbatim. Decorative for VoiceOver — confidence is exposed via
/// the source badge's accessibility label and the rationale sheet.
/// Tier + tooltip are precomputed by the row build.
struct SearchRowConfidenceBar: View, Equatable {
    /// Bar width; the row's content-column inset is measured from it.
    nonisolated static let width: CGFloat = 2

    let tier: SearchResultRow.ConfidenceTier
    let tooltip: String

    var body: some View {
        Rectangle()
            .fill(tier.color)
            .frame(width: Self.width)
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
    /// The row's already-computed floor-relative tier — an Equatable
    /// value type, so `.equatable()` at the call site keeps working
    /// off value content only.
    let tier: SearchResultRow.ConfidenceTier

    var body: some View {
        SearchResultRow.badgeView(
            for: result,
            isCustomHit: isCustomHit,
            isRegexHit: isRegexHit,
            tier: tier
        )
    }
}
