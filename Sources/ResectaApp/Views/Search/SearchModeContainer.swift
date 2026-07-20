import SwiftUI

// SEARCH-AND-REDACT §S2: Mode picker (Text / Regex / Multi-term) —
// the Search interface's second-level mode control. The Scan interface
// has no mode picker (its controls are category chips + scope), so
// this view renders only on the Search side and iterates the
// Search-side mode list rather than `allCases`.
// Per-mode option blocks live in `SearchToolbarSection`; this view owns
// just the picker so future mode-set changes add segments here without
// touching the rest of the toolbar.
//
// 3 × ~70pt = 210pt fits comfortably at iPhone 17 standard width
// (393pt); at high Dynamic Type the segmented row would overflow, so
// [RR-14](RISK_REGISTER.md#rr-14) routes through a `Menu` fallback at
// `.accessibility4`+.

struct SearchModeContainer: View {
    @Bindable var searchState: SearchState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The Search interface's modes. The scan mode is not a segment —
    /// it belongs to the Scan entry, and programmatic paths
    /// (saved-search recall and the `--searchMode=` hook) still set it
    /// directly on `searchModeType`.
    static let searchModes: [SearchModeType] = [.text, .regex, .multiTerm]

    /// [RR-14] AX-bound threshold, re-derived for 3 segments: the
    /// threshold was safe at 4 segments, and dropping a segment gives
    /// each remaining one ~33% more width ("Multi-term", the longest
    /// label, bounds the row), so `.accessibility4` carries with margin.
    static let menuFallbackThreshold: DynamicTypeSize = .accessibility4

    /// Pure predicate consumed by both `body` and unit tests.
    static func shouldUseMenuStyle(for size: DynamicTypeSize) -> Bool {
        size >= menuFallbackThreshold
    }

    var body: some View {
        Group {
            if Self.shouldUseMenuStyle(for: dynamicTypeSize) {
                Picker("Mode", selection: $searchState.searchModeType) {
                    ForEach(Self.searchModes, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            } else {
                Picker("Mode", selection: $searchState.searchModeType) {
                    ForEach(Self.searchModes, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        // Disabled while a search is in flight: a mode change mid-run
        // clears results without cancelling the active task, which
        // would otherwise keep streaming into the new mode's list.
        .disabled(searchState.isSearching)
        .accessibilityLabel("Search mode")
    }
}
