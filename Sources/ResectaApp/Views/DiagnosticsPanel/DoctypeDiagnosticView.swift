import SwiftUI
import RedactionEngine

// W9 — "Document profile" disclosure wired into the search sheet's footer.
// Renders the DoctypeExplanation produced by DocumentTypeClassifier.explain
// for the first scanned page text. Read-only diagnostic — no overrides,
// no mutation.
//
// WU-07 (2026-05-09): adds a banner-style rendering used by
// SearchResultsSection to surface the primary doctype + confidence
// always-visibly above PII Scan results, with single-tap disclosure
// for the gated-out detector count + per-category list.

struct DoctypeDiagnosticView: View {

    /// WU-07: render style. `.footerChip` is the original W9
    /// disclosure-only chip; `.banner(...)` promotes the primary doctype
    /// + detector count into an always-visible row above the results
    /// list with a dismiss button + disclosure tap.
    enum Style {
        case footerChip
        case banner(enabledPIICategories: Set<PIICategory>, onDismiss: () -> Void)
    }

    let explanation: DoctypeExplanation
    var style: Style = .footerChip

    var body: some View {
        switch style {
        case .footerChip:
            footerChipBody
        case .banner(let enabledCategories, let onDismiss):
            bannerBody(enabledCategories: enabledCategories, onDismiss: onDismiss)
        }
    }

    // MARK: - Footer chip (original W9 disclosure)

    private var footerChipBody: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xs) {
                ForEach(Array(explanation.topProbabilities.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: ResectaTokens.Spacing.sm) {
                        Text(Self.doctypeDisplayName(entry.0))
                            .font(.caption)
                            .frame(width: 80, alignment: .leading)
                        ProgressView(value: entry.1)
                            .tint(entry.0 == explanation.primary
                                  ? ResectaTokens.BrandTeal.tint
                                  : Color.secondary)
                        Text(String(format: "%.0f%%", entry.1 * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(Self.doctypeDisplayName(entry.0)), \(Int(entry.1 * 100)) percent")
                }

                if !explanation.keywordContributors.isEmpty {
                    Divider()
                        .padding(.vertical, 2)
                    Text(String(localized: "doctypeDiagnostic.topKeywordsHeader", table: "Legal"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(Array(explanation.keywordContributors.prefix(5).enumerated()),
                            id: \.offset) { _, kw in
                        HStack {
                            Text(kw.keyword)
                                .font(.caption.monospaced())
                            Spacer()
                            Text(Self.doctypeDisplayName(kw.classContributedTo))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text(String(localized: "doctypeDiagnostic.subtitle", table: "Legal"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, ResectaTokens.Spacing.xxs)
            }
            .padding(.top, ResectaTokens.Spacing.xxs)
        } label: {
            Label(
                String(localized: "doctypeDiagnostic.title", table: "Legal"),
                systemImage: "doc.text.magnifyingglass"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - WU-07 Banner (always-visible above PII Scan results)

    @ViewBuilder
    private func bannerBody(
        enabledCategories: Set<PIICategory>,
        onDismiss: @escaping () -> Void
    ) -> some View {
        let detectorCount = enabledCategories.count
        let doctypeLabel = Self.doctypeDisplayName(explanation.primary).lowercased()
        let gatedOut = Self.gatedOutCategories(
            for: explanation.primary,
            enabled: enabledCategories
        )

        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xs) {
            HStack(alignment: .top, spacing: ResectaTokens.Spacing.sm) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                DisclosureGroup {
                    bannerDisclosureContent(gatedOut: gatedOut)
                } label: {
                    // Single-purpose headline; gated detail
                    // behind the disclosure tap.
                    Text(WU07Strings.headline(detectorCount: detectorCount, doctype: doctypeLabel))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .accessibilityLabel(
                            "Scanning with \(detectorCount) detector\(detectorCount == 1 ? "" : "s") tuned for \(doctypeLabel) documents."
                        )
                }
                Spacer(minLength: ResectaTokens.Spacing.xs)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss doctype banner")
            }
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.xs)
        .background(Color.secondary.opacity(0.08))
    }

    @ViewBuilder
    private func bannerDisclosureContent(gatedOut: [PIICategory]) -> some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xs) {
            Text(WU07Strings.disclosureLabel(gatedCount: gatedOut.count))
                .font(.caption2)
                .foregroundStyle(.secondary)

            if gatedOut.isEmpty {
                Text("No detector categories are gated out for this document type.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(gatedOut, id: \.self) { category in
                    HStack(spacing: 4) {
                        Image(systemName: category.symbolName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(category.rawValue) gated out")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(category.rawValue) gated out for this document type")
                }
            }
        }
        .padding(.top, ResectaTokens.Spacing.xxs)
    }

    // MARK: - WU-07 Doctype-gating mirror
    //
    // App-side mirror of the engine's private `runsDOB/runsNPI/runsDEA/
    // runsAccount` rules at `Packages/.../PIIDetector.swift:320-341`.
    // The engine's `isDoctypeGatedOut(category:doctype:)` is `private
    // static`, so the banner cannot consume it directly. This mirror
    // covers the same 4 categories (DOB/NPI/DEA/Account) — every other
    // category returns `false` from the engine helper today.
    //
    // TODO: when the engine extends the gate to all 7
    // categories (DOB/MRN/NPI/DEA/Account/Bates/LicensePlate),
    // this mirror updates in parallel. The banner is data-driven so the
    // UI is a no-op once parity ships. The
    // `gatedOutMirrorMatchesEngine` parity test will fail loudly if
    // the engine drifts ahead of the app-side mirror.

    static func gatedOutCategories(
        for doctype: DoctypeClass,
        enabled: Set<PIICategory>
    ) -> [PIICategory] {
        PIICategory.allCases
            .filter { enabled.contains($0) && Self.isCategoryGatedOut(category: $0, doctype: doctype) }
    }

    static func isCategoryGatedOut(category: PIICategory, doctype: DoctypeClass) -> Bool {
        switch category {
        // dob now runs on every doctype — financial
        // uses the label-anchored path only (bare dates stay suppressed
        // there), so it is no longer gated OUT anywhere.
        case .dateOfBirth: return false
        case .npi: return !(doctype == .medical || doctype == .foia)
        case .dea: return doctype != .medical
        // CND-10 (launch-fix-v2 S5): mirrors the broadened
        // PIIDetector.runsAccount — court + generic added, .foia held.
        case .account: return !(doctype == .financial || doctype == .medical
            || doctype == .court || doctype == .generic)
        // Mirrors PIIDetector.runsRoutingNumber.
        case .routingNumber: return !(doctype == .financial || doctype == .generic)
        default: return false
        }
    }

    static func doctypeDisplayName(_ c: DoctypeClass) -> String {
        switch c {
        case .court: "Court"
        case .medical: "Medical"
        case .financial: "Financial"
        case .foia: "Government records"
        case .generic: "General"
        }
    }
}

// MARK: - WU-07 Banner copy
//
// Strings classified per §19. SAFE: "tuned for" describes the gating
// rule the detectors apply, not an outcome promise. Kept off
// `Legal.xcstrings` because they are operational copy, not legal/
// marketing copy. Audit acceptance rule:
// disclosure copy must NOT make outcome promises about the gating
// (see the M-1 forbidden-phrase set in CONTRIBUTING's audit checklist).

enum WU07Strings {
    /// Banner headline. Singular/plural and lower-cased
    /// doctype name produce: "Scanning with 7 detectors tuned for
    /// medical documents." or "Scanning with 1 detector tuned for
    /// court documents."
    static func headline(detectorCount: Int, doctype: String) -> String {
        let suffix = detectorCount == 1 ? "" : "s"
        return "Scanning with \(detectorCount) detector\(suffix) tuned for \(doctype) documents."
    }

    /// Disclosure-row label that precedes the gated-out list.
    static func disclosureLabel(gatedCount: Int) -> String {
        let suffix = gatedCount == 1 ? "" : "s"
        return "Detector gating · \(gatedCount) detector\(suffix) gated out"
    }
}
