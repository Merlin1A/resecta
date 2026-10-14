import SwiftUI
import RedactionEngine

// The three banners the results list mounts above its rows, each a
// `View` with explicit inputs rather than a read of the section's own
// state: the saturation banner with its re-target shortcuts, the
// per-page regex-timeout banner and the per-page OCR-skip banner. The
// headline builders stay addressable as `SearchResultsSection.` statics
// (the extension at the end) because the scan review, the verification
// results screen and their tests read them there.

    /// Saturation message promoted from a flat
    /// `Image + Text` row to an actionable banner with three inline
    /// shortcuts that re-target the saturated query. Each shortcut
    /// mutates the corresponding `searchState` field then invokes
    /// `onTriggerSearch` so the saturated query re-runs with the new
    /// constraint without waiting for the next debounce. Banner appear/
    /// disappear stays inside the existing `livePreviewRow` show/hide
    /// branch — no new explicit transition. Reduce Motion preserved
    /// via the `reduceMotion` environment threaded above.
    /// "Add whole-word filter" / "Toggle case-sensitive" / "Scope to
    /// current page" are mechanism-description action labels.
struct SearchSaturationBanner: View {
    let searchState: SearchState
    let onTriggerSearch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xs) {
            HStack(spacing: ResectaTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text(SaturationBannerCopy.headline)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                Spacer()
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: ResectaTokens.Spacing.sm) {
                Button {
                    searchState.options.wholeWord = true
                    onTriggerSearch()
                } label: {
                    Text(SaturationBannerCopy.addWholeWord)
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(searchState.options.wholeWord || searchState.isSearching)
                .accessibilityLabel(SaturationBannerCopy.addWholeWord)

                Button {
                    searchState.options.caseSensitive.toggle()
                    onTriggerSearch()
                } label: {
                    Text(SaturationBannerCopy.toggleCaseSensitive)
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(searchState.isSearching)
                .accessibilityLabel(SaturationBannerCopy.toggleCaseSensitive)

                // Dark with the scope picker — with the
                // picker retired this shortcut was a one-way door into
                // page-scoped traversal with no readout and no way
                // back. The banner and its two option legs stay; the
                // model chain (`scopeToCurrentPage()`) stays compiled
                // and unit-pinned.
                if SearchState.navigationScopeControlsEnabled {
                    Button {
                        scopeSaturatedSearchToCurrentPage()
                    } label: {
                        Text(SaturationBannerCopy.scopeToCurrentPage)
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(searchState.navigationScope == .currentPage || searchState.isSearching)
                    .accessibilityLabel(SaturationBannerCopy.scopeToCurrentPage)
                }
            }
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.xs)
        .background(Color.orange.opacity(0.08))
    }

    /// Scope-to-current-page handler for the
    /// saturation banner. Delegates the flush → cancel → scope chain
    /// to `SearchState.scopeToCurrentPage()` (testable) then invokes
    /// `onTriggerSearch` so the saturated query re-runs against the
    /// page-scoped constraint. The page index that the
    /// `.currentPage` filter resolves against is read fresh by
    /// `scopedResults(currentPageIndex:)` at J/K-tap time —
    /// `documentState.currentPageIndex` is captured at tap time
    /// transitively through the SwiftUI button action firing
    /// synchronously when the user taps.
    private func scopeSaturatedSearchToCurrentPage() {
        Task { @MainActor in
            await searchState.scopeToCurrentPage()
            onTriggerSearch()
        }
    }
}

    /// Surfaces when one or more pages bailed on
    /// the regex per-page timeout. Copy NEVER echoes pattern text —
    /// uses only the generic active-pattern phrasing so a
    /// pasted PII-like regex can't leak via the banner. Pinned by
    /// `RegexTimeoutBannerTests.bannerCopyNeverEchoesPattern` (the test
    /// feeds a known-distinctive pattern and greps the banner output).
struct SearchRegexTimeoutBanner: View {
    let searchState: SearchState

    var body: some View {
        let pages = searchState.regexTimeoutPages.sorted()
        let headline = SearchResultsSection.regexTimeoutBannerHeadline(pages: pages)
        return HStack(alignment: .top, spacing: ResectaTokens.Spacing.sm) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.secondary)
            Text(headline)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: ResectaTokens.Spacing.xs)
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.xs)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline)
    }
}

    /// Surfaces when one or more pages exceeded the OCR pixel caps during
    /// the active scan, so OCR never ran there. Same shape as the
    /// regex-timeout banner above; copy names only page numbers, never
    /// document content. Pinned by `OCRSkipBannerTests`.
struct SearchOCRSkipBanner: View {
    let searchState: SearchState

    var body: some View {
        let pages = searchState.ocrSkippedPages.sorted()
        let headline = SearchResultsSection.ocrSkipBannerHeadline(pages: pages)
        return HStack(alignment: .top, spacing: ResectaTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(headline)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: ResectaTokens.Spacing.xs)
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.xs)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline)
    }
}

// MARK: - Banner headline builders

extension SearchResultsSection {
    /// Banner headline copy. Pages are 0-indexed internally;
    /// rendered as 1-based page numbers for the user.
    static func regexTimeoutBannerHeadline(pages: [Int]) -> String {
        let oneBased = pages.map { $0 + 1 }
        let list = formatPageList(oneBased)
        let pageNoun = oneBased.count == 1 ? "page" : "pages"
        return "The active regex pattern timed out on \(pageNoun) \(list). Results may be incomplete."
    }
    /// Banner headline. Pages are 0-indexed internally; rendered
    /// as 1-based page numbers for the user. Mechanism description only.
    static func ocrSkipBannerHeadline(pages: [Int]) -> String {
        let oneBased = pages.map { $0 + 1 }
        let list = formatPageList(oneBased)
        let pageNoun = oneBased.count == 1 ? "Page \(list) was" : "Pages \(list) were"
        return "\(pageNoun) too large to scan for text — image content there was not searched."
    }
    /// English-list formatter for page numbers. "3" / "3 and 5"
    /// / "3, 5, and 7". Caller passes 1-based numbers.
    static func formatPageList(_ pages: [Int]) -> String {
        switch pages.count {
        case 0:  return ""
        case 1:  return "\(pages[0])"
        case 2:  return "\(pages[0]) and \(pages[1])"
        default:
            let leading = pages.dropLast().map(String.init).joined(separator: ", ")
            return "\(leading), and \(pages.last!)"
        }
    }
}
