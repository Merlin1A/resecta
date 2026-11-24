import SwiftUI

extension SearchAndRedactSheet {
    // MARK: - Search Bar

    var searchBar: some View {
        HStack(spacing: ResectaTokens.Spacing.sm) {
            if searchState.searchModeType == .piiScan {
                // Scan interface leading controls: the ↻ re-run —
                // relocated here from the retired category-chips row,
                // and hidden again whenever the DEBUG reveal restores
                // that row so the surface never renders two run
                // controls — and the saved-searches bookmark, relocated
                // from the retired scope row (this home is reachable at
                // every detent; the scope row never was at compact).
                // Entry auto-run still starts scans (the one-tap
                // contract); the row keeps its cancel-while-searching
                // and result-navigation jobs at the trailing edge,
                // giving Scan the same leading-controls … trailing-nav
                // read as Search.
                    scanRescanButton
                savedSearchesBookmark
                Spacer(minLength: 0)
            } else if searchState.searchModeType == .multiTerm {
                TextField("Add term…", text: $searchState.queryText)
                    .textFieldStyle(.roundedBorder)
                    // The typed term may itself be PII
                    // (a user searching their own SSN).
                    .privacySensitive()
                    // Search input is verbatim: autocapitalization would
                    // rewrite case-sensitive terms and autocorrect can
                    // silently replace the typed term before it runs.
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .writingToolsBehavior(.disabled)
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        // Route every multi-term submission
                        // through the pure validator (length cap BEFORE
                        // duplicate so an over-cap dup-of-existing entry
                        // surfaces the more specific copy).
                        let outcome = Self.validateMultiTermSubmission(
                            rawText: searchState.queryText,
                            existingTerms: searchState.searchTerms
                        )
                        switch outcome {
                        case .rejectedEmpty:
                            // Return on an empty field runs the staged
                            // terms, unless their results are listed or
                            // arriving (`SearchState.returnStartsRun`).
                            if searchState.returnStartsRun {
                                triggerSearch()
                            }
                            return
                        case .rejectedTooLong(let message):
                            searchState.queryText = ""
                            duplicateTermMessage = message
                            return
                        case .rejectedDuplicate(let message):
                            // Case-insensitive duplicate guard.
                            searchState.queryText = ""
                            duplicateTermMessage = message
                            return
                        case .accepted(let trimmed):
                            duplicateTermMessage = nil
                            searchState.searchTerms.append(trimmed)
                            searchState.queryText = ""
                            triggerSearch()
                        }
                    }
                    .accessibilityLabel("Search term input")
            } else {
                TextField("Search text…", text: $searchState.queryText)
                    .textFieldStyle(.roundedBorder)
                    // The typed query may itself be PII.
                    .privacySensitive()
                    // Verbatim input: autocapitalization breaks
                    // case-sensitive queries and mangles regex patterns;
                    // autocorrect can silently rewrite the query.
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .writingToolsBehavior(.disabled)
                    .focused($isSearchFieldFocused)
                    .accessibilityLabel("Search text")
                    // Return runs the current query — the explicit-run
                    // affordance for carried queries the mode switch
                    // deliberately does not auto-run, and for short
                    // queries below the debounce floor.
                    .onSubmit {
                        // A whitespace-only Return runs nothing, and a
                        // Return on the search whose results are listed
                        // or arriving only puts the keyboard away
                        // (`SearchState.returnStartsRun`).
                        if searchState.returnStartsRun {
                            triggerSearch()
                        }
                    }
                    .onChange(of: searchState.queryText) { _, newValue in
                        debounceSearch(query: newValue)
                        scheduleLivePreviewIfApplicable()
                    }
            }

            // Saved-searches entry point for the Search interface —
            // by the field so it stays reachable at the compact
            // detent. The Scan interface renders the SAME
            // `savedSearchesBookmark` from its leading branch above —
            // one shared component, two per-mode render sites, so
            // exactly one bookmark shows per mode.
            if searchState.searchModeType != .piiScan {
                savedSearchesBookmark
            }

            if searchState.isSearching {
                Button {
                    Task { await searchState.cancelSearch() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Cancel search")
            }

            // Prev/Next navigation + position indicator.
            if showsResultNavCluster {
                resultNavigationControls
            }
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.sm)
    }

    /// Shared label chrome for the sheet's circular icon buttons (the
    /// toolbar section's `rescanButton` draws through it too) — an
    /// 18pt SF glyph in a drawn Ø44 circle whose wash is matched by eye
    /// to the retired `.bordered`-small background, floored to the
    /// `TouchTarget.minimum` LAYOUT square with the floor AFTER the
    /// chrome (hit area unchanged, visual back to circle scale; hit
    /// expansion beyond the layout frame is banned).
    /// Interaction states live on `CircularIconButtonStyle`.
    static func circularIconLabel(
        _ systemName: String,
        diameter: CGFloat = CircularIconButtonStyle.diameter,
        glyphPointSize: CGFloat = CircularIconButtonStyle.glyphPointSize
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: glyphPointSize))
            .foregroundStyle(ResectaTokens.BrandTeal.text)
            .frame(width: diameter, height: diameter)
            .background(CircularIconButtonStyle.wash, in: Circle())
            .frame(
                width: ResectaTokens.TouchTarget.minimum,
                height: ResectaTokens.TouchTarget.minimum
            )
            .contentShape(Rectangle())
    }

    /// Bookmark button presenting the saved-searches list through the
    /// single modal slot. This is the one live bookmark for BOTH
    /// interfaces (Scan renders it from the search bar's leading
    /// branch; the scope-row sibling is dormant).
    private var savedSearchesBookmark: some View {
        Button {
            activeModal = .savedSearches
        } label: {
            // Drawn Ø44 circle + 18pt glyph in place of the
            // `.bordered` wash that rendered the touch-target floor as
            // a ~64pt slab; hit area unchanged.
            Self.circularIconLabel("bookmark")
        }
        .buttonStyle(.circularIcon)
        .accessibilityLabel("Saved Searches")
        .accessibilityIdentifier("savedSearchesBookmark")
    }

    /// Compact re-run control for the Scan interface bar — the
    /// relocated home of the retired chips-row ↻.
    private var scanRescanButton: some View {
        Button {
            triggerSearch()
        } label: {
            Self.circularIconLabel("arrow.clockwise")
        }
        .buttonStyle(.circularIcon)
        .disabled(searchState.isSearching)
        .accessibilityLabel("Scan document for PII")
        .accessibilityIdentifier("rescanButton")
    }
}
