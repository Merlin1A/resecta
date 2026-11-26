import SwiftUI
import RedactionEngine

// The saturation banner the results list mounts in its live preview row,
// and the headline builders of what a search did not read. The notice place
// above the results (`SearchNoticePlaceView`) shows those sentences. The
// builders stay addressable as `SearchResultsSection.` statics (the
// extension at the end) because the notice place, the scan review, the
// verification results screen and their tests read them there.

    /// Saturation message promoted from a flat
    /// `Image + Text` row to an actionable banner with two inline
    /// shortcuts that re-target the saturated query. Each shortcut
    /// mutates the corresponding `searchState` field then invokes
    /// `onTriggerSearch` so the saturated query re-runs with the new
    /// constraint without waiting for the next debounce. Banner appear/
    /// disappear stays inside the existing `livePreviewRow` show/hide
    /// branch — no new explicit transition. Reduce Motion preserved
    /// via the `reduceMotion` environment threaded above.
    /// "Add whole-word filter" / "Toggle case-sensitive" are
    /// mechanism-description action labels.
    /// The caution is said twice: the glyph in the caution mark and the fill
    /// in the warning tint. The headline is in the label colour.
struct SearchSaturationBanner: View {
    let searchState: SearchState
    let onTriggerSearch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xs) {
            HStack(spacing: ResectaTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(ResectaTokens.Ink.cautionMark)
                Text(SaturationBannerCopy.headline)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
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

            }
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.xs)
        .background(ResectaTokens.SemanticColor.warningTint.opacity(0.08))
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
    /// Banner headline. Pages are 0-indexed internally; rendered as
    /// 1-based page numbers for the user.
    static func widenedBoxBannerHeadline(pages: [Int]) -> String {
        let oneBased = pages.map { $0 + 1 }
        let pageNoun = oneBased.count == 1 ? "page" : "pages"
        return "Some boxes on \(pageNoun) \(formatPageList(oneBased)) were drawn larger than their words, because the "
            + "text could not be fitted to the printed words. Keep them that size: shrinking one can leave part of a word readable."
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
