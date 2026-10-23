import SwiftUI
import PDFKit
import RedactionEngine

// The editor's toolbar, moved out of `DocumentEditorView.swift` (the hub)
// along its `// MARK: - Toolbar Leading Items` · `Toolbar Trailing Items` ·
// `Toolbar Components` seams: the leading items (the draw and search
// entries, the results screen's Home), the trailing items (undo and redo,
// the iPad selection controls, Redact, Stop, Settings), the iPhone
// overflow, and the selection components they mount. A TYPE with explicit
// inputs: the state it reads, the bindings it writes, and the actions and
// views the editor hands it. The editor builds it for its `.toolbar` block.

struct DocumentEditorToolbar {
    let documentState: DocumentState
    let redactionState: RedactionState
    let coordinator: PipelineCoordinator
    let horizontalSizeClass: UserInterfaceSizeClass?
    let undoManager: UndoManager?
    @Binding var activeTool: DocumentEditorView.DrawingTool?
    @Binding var isMultiSelectActive: Bool
    @Binding var showSettings: Bool
    let documentOverride: PipelineMode?
    let redactButtonDisabled: Bool
    let redactButtonHint: String
    let handleHomeTap: () -> Void
    let homeButton: AnyView
    let pipelineModePicker: AnyView
    let deleteSelectedRegions: () -> Void

    /// The one reset of the canvas tools: the draw tool off and Add to
    /// Selection off. The editor calls it when a different document
    /// replaces the open one, so neither carries into the new document.
    func resetCanvasTools() {
        activeTool = nil
        isMultiSelectActive = false
    }

    // MARK: - Toolbar Leading Items

    /// Routine actions render neutral — the group's
    /// ambient tint is `.primary`, applied here (inside the property,
    /// not at the `.toolbar {}` call site — see the comment above). Per-
    /// element overrides (the draw tools' `.tint(active ? BrandTeal.tint
    /// : nil)`) still win: `nil` now inherits this neutral instead of
    /// the root's brand teal, so only the ACTIVE tool stays teal.
    @ViewBuilder
    var leadingToolbarItems: some View {
        Group {
        switch documentState.phaseKind {
        case .editing:
            // Drawing tools.
            // iPhone nav-bar overflow: keep a CONSTANT-width glyph per draw tool
            // and signal "active" via .tint only. A wider active glyph (the former
            // rectangle.dashed.badge.checkmark / scribble.variable) grows the leading
            // ToolbarItemGroup past the bar width and collapses the whole group into the
            // system "…" overflow menu.
            Button("Rectangle", systemImage: "rectangle.dashed") {
                // Draw wins: entering the tool drops the
                // selection and the Add-to-Selection toggle so the next
                // drag draws instead of resizing or marquee-selecting.
                let entering = activeTool != .rectangle
                activeTool = entering ? .rectangle : nil
                let effects = DocumentEditorView.drawToolEntryEffects(entering: entering)
                if effects.clearSelection { redactionState.selectedRegionIDs = [] }
                if effects.disableMultiSelect { isMultiSelectActive = false }
            }
            .tint(activeTool == .rectangle ? ResectaTokens.BrandTeal.tint : nil)
            .accessibilityIdentifier("drawTool")
            .accessibilityValue(activeTool == .rectangle
                                ? "Drawing mode active" : "Tap to enter drawing mode")

            // Two peer entry points into the one search-and-scan sheet
            // (two interfaces over one chassis). Both open the same
            // sheet pre-switched to the tapped interface; they replace
            // the former Auto-Detect menu + Search & Redact button.
            //
            // [Scan] keeps the one-tap contract: the tap arms a
            // one-shot auto-run flag the sheet consumes on appear, so
            // one tap opens the sheet AND runs a full scan with no
            // second confirm. The run is trigger-driven from there
            // (chips / options configure the NEXT run).
            Button("Scan", systemImage: "doc.viewfinder") {
                let state = SearchState()
                state.searchModeType = .piiScan
                state.pendingAutoRunScan = true
                redactionState.activeSearch = state
            }
            .disabled(documentState.phaseKind != .editing
                      || redactionState.activeSearch != nil)
            // Identifier is PLUMBING and carries over from the
            // Auto-Detect entry this button renames — UI tests anchor
            // on it, and it is deliberately not the display string.
            .accessibilityIdentifier("autoDetect")

            // [Search] opens the literal-search interface. A fresh
            // SearchState defaults to `.text` — the Search side.
            Button("Search", systemImage: "magnifyingglass") {
                redactionState.activeSearch = SearchState()
            }
            .disabled(documentState.phaseKind != .editing
                      || redactionState.activeSearch != nil)
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityIdentifier("searchRedact")
        case .verified:
            // Home lives top-left on the verification results screen
            // (the former Done label/glyph became Home — the same
            // `house` glyph as the editor's overflow entry). The action is
            // the Done teardown, lifted from VerificationActionBar when the
            // bottom bar was removed; the confirmation dialog (pinned
            // by VerificationActionBarDoneConfirmationTests)
            // still gates sessions that carry drawn regions. Identifier
            // kept (plumbing). Routed through
            // `handleHomeTap()` so a sheet that is somehow still presented
            // on this screen takes the park-then-dialog route
            // instead of the refused second presentation (a staged review
            // cannot be pending after an Apply, so the confirm gate
            // resolves to `hasDrawnRegions` here as before).
            Button("Home", systemImage: "house") {
                handleHomeTap()
            }
            .accessibilityIdentifier("verificationDoneButton")
        default:
            EmptyView()
        }
        }
        .tint(.primary)
    }

    // MARK: - Toolbar Trailing Items

    /// Same neutral-group rule as `leadingToolbarItems`
    /// above.
    @ViewBuilder
    var trailingToolbarItems: some View {
        Group {
        switch documentState.phaseKind {
        case .editing:
            // Undo/redo always visible (both iPhone and iPad)
            undoRedoButtons

            // iPad: additional edit actions visible in toolbar
            if horizontalSizeClass == .regular {
                selectionMenu
                selectMoreToggle
                deleteButton
                batchOpsMenu
                pipelineModePicker
            }

            // Redact button — always visible. This is the ONE
            // designated emphasis action in this toolbar — explicit
            // brand tint so it stands out against the neutral group.
            Button("Redact", systemImage: "scissors") {
                coordinator.runFullPipeline(documentOverride: documentOverride)
            }
            .tint(ResectaTokens.BrandTeal.tint)
            // The gate (`+RedactGate`): effective regions, the pipeline-start
            // predicate, no selected-but-unapplied matches. The shortcut
            // inherits `.disabled`.
            .disabled(redactButtonDisabled)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .accessibilityIdentifier("redactButton")
            .accessibilityHint(redactButtonHint)

            settingsButton

        case .detecting, .redacting:
            // Single cancel button
            Button("Stop Processing", systemImage: "stop.circle") {
                documentState.cancelActivePipeline(redactionState: redactionState)
            }
            .accessibilityIdentifier("stopProcessing")
            .accessibilityHint("Stops processing. Your document is preserved.")

        case .verifying:
            // Single cancel button
            Button("Stop Verification", systemImage: "stop.circle") {
                documentState.cancelActivePipeline(redactionState: redactionState)
            }
            .accessibilityIdentifier("stopProcessing")
            .accessibilityHint("Stops processing. Your document is preserved.")

        default:
            // .verified, .failed — settings gear only.
            // `.empty` flashes Color.clear and auto-returns home
            // (Phase 1 redesign) — this trailing branch is unreachable
            // for that phase but kept as a defense-in-depth fallback
            // during the 150ms debounce window.
            settingsButton
        }
        }
        .tint(.primary)
    }

    @ViewBuilder
    private var settingsButton: some View {
        Button("Settings", systemImage: "gearshape") {
            showSettings = true
        }
        .accessibilityIdentifier("settings-button")
    }

    /// iPhone overflow menu — same neutral-group rule.
    /// Extracted to its own property (mirrors `leadingToolbarItems` /
    /// `trailingToolbarItems`) so the tint is isolated from the
    /// `.toolbar {}` result-builder closure.
    @ViewBuilder
    var secondaryActionToolbarItems: some View {
        Group {
            homeButton
            markWholePageButton
            selectionMenu
            selectMoreToggle
            deleteButton
            batchOpsMenu
            pipelineModePicker
        }
        .tint(.primary)
    }

    // MARK: - Toolbar Components

    /// Mark Whole Page in the overflow: the page bar's own action on the
    /// page in view. It shows for every page count; the page bar's
    /// button is hidden on a one-page document.
    @ViewBuilder
    private var markWholePageButton: some View {
        Button("Mark Whole Page", systemImage: "rectangle.inset.filled") {
            markWholePage()
        }
        .accessibilityIdentifier("overflowMarkWholePage")
    }

    /// The overflow row's action — `PageNavigationBar.markWholePage`, the
    /// one home of the whole-page region.
    func markWholePage() {
        PageNavigationBar.markWholePage(
            redactionState: redactionState, documentState: documentState, undoManager: undoManager)
    }

    @ViewBuilder
    private var undoRedoButtons: some View {
        Button("Undo", systemImage: "arrow.uturn.backward") {
            undoManager?.undo()
        }
        .disabled(!(undoManager?.canUndo ?? false))
        .keyboardShortcut("z", modifiers: .command)

        Button("Redo", systemImage: "arrow.uturn.forward") {
            undoManager?.redo()
        }
        .disabled(!(undoManager?.canRedo ?? false))
        .keyboardShortcut("z", modifiers: [.command, .shift])
    }

    @ViewBuilder
    private var deleteButton: some View {
        let count = redactionState.selectedRegionIDs.count
        if count > 0 {
            // Deletes at once, any count: one Undo step restores them all.
            Button(deleteButtonLabel, systemImage: "trash") { deleteSelectedRegions() }
            .tint(.red)
            // Command-Delete: a bare Delete key belongs to the text field it edits.
            .keyboardShortcut(.delete, modifiers: [.command])
        }
    }

    // "More" menu that bundles batch operations on the active
    // selection. Visible only when `selectedRegionIDs.isEmpty == false`,
    // gated by `batchOpsMenuShouldShow(selectedCount:)`. "Delete Selected"
    // deletes at once, like the toolbar's Delete; Undo restores them.
    @ViewBuilder
    private var batchOpsMenu: some View {
        let selectedCount = redactionState.selectedRegionIDs.count
        if DocumentEditorView.batchOpsMenuShouldShow(selectedCount: selectedCount) {
            let page = documentState.currentPageIndex
            let pageRegions = redactionState.regions[page] ?? []
            Menu {
                Button("Select All on Page", systemImage: "checkmark.circle") {
                    redactionState.selectedRegionIDs = Set(pageRegions.map(\.id))
                }
                .disabled(selectedCount == pageRegions.count)
                Button("Deselect", systemImage: "xmark.circle") {
                    redactionState.selectedRegionIDs = []
                }
                Button(role: .destructive) {
                    deleteSelectedRegions()
                } label: {
                    Label("Delete Selected", systemImage: "trash")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("canvasBatchOpsMenu")
        }
    }

    // "Select More" toolbar toggle. While on, a tap on a region
    // adds to selection rather than replacing it — iPhone parity for
    // the iPad Shift+tap path. Visible only when the current page has
    // regions to select. Count surfaces in the label so the user sees
    // the running selection size without opening a separate badge.
    @ViewBuilder
    private var selectMoreToggle: some View {
        let page = documentState.currentPageIndex
        let pageRegionCount = redactionState.regions[page]?.count ?? 0
        let selectedCount = redactionState.selectedRegionIDs.count
        if pageRegionCount > 0 {
            Button {
                isMultiSelectActive.toggle()
                // Mutual exclusion with the Rectangle tool:
                // whichever was activated last wins.
                if isMultiSelectActive { activeTool = nil }
            } label: {
                Label(
                    RedactionOverlayView.selectMoreToggleLabel(selectedCount: selectedCount),
                    systemImage: isMultiSelectActive
                        ? "checkmark.square.fill"
                        : "checkmark.square"
                )
            }
            .tint(isMultiSelectActive ? ResectaTokens.BrandTeal.tint : nil)
            .accessibilityIdentifier("selectMoreToggle")
            .accessibilityValue(isMultiSelectActive
                                ? "On. Tapping a region adds it to the selection."
                                : "Off. Tapping a region replaces the selection.")
        }
    }

    // Select All / Deselect All menu — touch-accessible on both platforms
    @ViewBuilder
    private var selectionMenu: some View {
        let page = documentState.currentPageIndex
        let pageRegionCount = redactionState.regions[page]?.count ?? 0
        let selectedCount = redactionState.selectedRegionIDs.count
        if pageRegionCount > 0 {
            Menu {
                Button("Select All on Page", systemImage: "checkmark.circle") {
                    redactionState.selectedRegionIDs = Set(
                        (redactionState.regions[page] ?? []).map(\.id))
                }
                .disabled(selectedCount == pageRegionCount)
                if selectedCount > 0 {
                    Button("Deselect All", systemImage: "xmark.circle") {
                        redactionState.selectedRegionIDs = []
                    }
                }
            } label: {
                // Verb-object menu label (was the bare noun
                // "Selection").
                // The off state is a none-selected STATE
                // indicator, not an action icon — plain "circle"
                // instead of the unfilled checkmark glyph.
                Label("Select Regions", systemImage: selectedCount > 0
                      ? "checkmark.circle.fill" : "circle")
            }
        }
    }

    var deleteButtonLabel: String {
        let count = redactionState.selectedRegionIDs.count
        return count > 1 ? "Delete \(count) Regions" : "Delete Region"
    }
}

extension DocumentEditorView {
    /// Visibility predicate. The "More" menu surfaces only when at
    /// least one region is selected. Pure function so the gate is testable
    /// without a SwiftUI host.
    static func batchOpsMenuShouldShow(selectedCount: Int) -> Bool {
        selectedCount > 0
    }
}
