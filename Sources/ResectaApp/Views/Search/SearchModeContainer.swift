import SwiftUI

// SEARCH-AND-REDACT §S2: Mode picker (Text / Regex / Multi-term / PII Scan).
// Per-mode option blocks live in `SearchToolbarSection`; this view owns
// just the picker so future mode-set changes add segments here without
// touching the rest of the toolbar.
//
// 4 × ~70pt = 280pt fits comfortably at iPhone 17 standard width
// (393pt); at high Dynamic Type the segmented row would overflow, so
// [RR-14](RISK_REGISTER.md#rr-14) routes through a `Menu` fallback at
// `.accessibility3`+.

struct SearchModeContainer: View {
    @Bindable var searchState: SearchState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// [RR-14] AX-bound threshold. At 4 segments the segmented picker
    /// fits comfortably one level deeper into the AX range before the
    /// menu fallback engages.
    static let menuFallbackThreshold: DynamicTypeSize = .accessibility4

    /// Pure predicate consumed by both `body` and unit tests.
    static func shouldUseMenuStyle(for size: DynamicTypeSize) -> Bool {
        size >= menuFallbackThreshold
    }

    var body: some View {
        Group {
            if Self.shouldUseMenuStyle(for: dynamicTypeSize) {
                Picker("Mode", selection: $searchState.searchModeType) {
                    ForEach(SearchModeType.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            } else {
                Picker("Mode", selection: $searchState.searchModeType) {
                    ForEach(SearchModeType.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .accessibilityLabel("Search mode")
    }
}
