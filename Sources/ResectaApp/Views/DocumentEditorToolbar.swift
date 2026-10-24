import SwiftUI
import UIKit
import PDFKit
import RedactionEngine

// The editor's toolbar, moved out of `DocumentEditorView.swift` (the hub)
// along its `// MARK: - Toolbar Leading Items` · `Toolbar Trailing Items` ·
// `Toolbar Components` seams: the leading items (the draw and search
// entries, the results screen's Home), the trailing items (the Undo
// control, the iPad selection controls, Redact, Stop, Settings), the iPhone
// … menu, and the selection components they mount. A TYPE with explicit
// inputs: the state it reads, the bindings it writes, and the actions and
// views the editor hands it. `EditorToolbarContent` (below) lays it out as
// the editor's toolbar; on iPhone, `EditorToolbarLayout` decides which
// controls sit in the bar and which in the … menu.

struct DocumentEditorToolbar {
    let documentState: DocumentState
    let redactionState: RedactionState
    let coordinator: PipelineCoordinator
    let horizontalSizeClass: UserInterfaceSizeClass?
    let undoManager: UndoManager?
    @Binding var activeTool: DocumentEditorView.DrawingTool?
    @Binding var isMultiSelectActive: Bool
    /// The search sheet's detent: every Scan or Search entry opens at medium.
    @Binding var searchSheetDetent: PresentationDetent
    let documentOverride: PipelineMode?
    let redactButtonDisabled: Bool
    let redactButtonHint: String
    let handleHomeTap: () -> Void
    let homeButton: AnyView
    let pipelineModePicker: AnyView
    /// Settings, parking the search sheet first when it is up.
    let openSettings: () -> Void

    /// The one reset of the canvas tools: the draw tool off and Add to
    /// Selection off. The editor calls it when a different document
    /// replaces the open one, so neither carries into the new document.
    /// The Rectangle tool's hint while VoiceOver is running.
    static let rectangleVoiceOverHint = "Drawing needs direct touch. Use Search or Scan."

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
                if effects.clearSelection { redactionState.deselectAllRegions() }
                if effects.disableMultiSelect { isMultiSelectActive = false }
            }
            .tint(activeTool == .rectangle ? ResectaTokens.BrandTeal.tint : nil)
            .accessibilityIdentifier("drawTool")
            .accessibilityValue(activeTool == .rectangle
                                ? "Drawing mode active" : "Tap to enter drawing mode")
            // A drag cannot draw under VoiceOver: the tool is off, and says why.
            .disabled(UIAccessibility.isVoiceOverRunning)
            .accessibilityHint(UIAccessibility.isVoiceOverRunning ? Self.rectangleVoiceOverHint : "")

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
                searchSheetDetent = .medium
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
                searchSheetDetent = .medium
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
            // The iPad's editing bar (an iPhone's lays out through
            // `EditorToolbarContent`): Undo, the selection controls, Redact,
            // Settings.
            undoControl

            if horizontalSizeClass == .regular {
                selectionMenu
                selectMoreToggle
                deleteButton
                pipelineModePicker
            }

            redactButton

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
            openSettings()
        }
        .accessibilityIdentifier("settings-button")
    }

    /// Redact — the ONE designated emphasis action in this toolbar,
    /// with an explicit brand tint so it stands out against the neutral
    /// group. One builder for both of its places: the bar's prominent
    /// glass button, and the … menu's row at the largest text sizes.
    @ViewBuilder
    var redactButton: some View {
        Button("Redact", systemImage: "scissors") { redactTapped() }
        .tint(ResectaTokens.BrandTeal.tint)
        // The gate (`+RedactGate`): disabled only when there is no region
        // to redact or a run cannot start; the shortcut inherits it.
        .disabled(redactButtonDisabled)
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .accessibilityIdentifier("redactButton")
        .accessibilityHint(redactButtonHint)
    }

    /// Redact's tap and ⇧⌘R: with selected matches not yet applied, the
    /// search sheet comes up to where they are, and the run funnel refuses
    /// with their notice; otherwise the run starts.
    func redactTapped() {
        if DocumentEditorView.redactTapRoute(documentState: documentState, redactionState: redactionState)
            == .raiseSheetAndExplain {
            searchSheetDetent = .medium
        }
        coordinator.runFullPipeline(documentOverride: documentOverride)
    }

    /// The iPhone … menu — same neutral-group rule — in the layout's
    /// sections: the selection actions, then Switch Mode and Settings (and
    /// Redact first there at the largest sizes), then Home.
    func secondaryActionToolbarItems(layout: EditorToolbarLayout) -> some View {
        Group {
            ForEach(Array(layout.overflowSections.enumerated()), id: \.offset) { _, section in
                Section {
                    ForEach(section, id: \.self) { overflowRow($0) }
                }
            }
        }
        .tint(.primary)
    }

    @ViewBuilder
    private func overflowRow(_ control: EditorToolbarLayout.Control) -> some View {
        switch control {
        case .selectRegions: selectionMenu
        case .addToSelection: selectMoreToggle
        case .delete: deleteButton
        case .markWholePage: markWholePageButton
        case .redact: redactButton
        case .switchMode: pipelineModePicker
        case .settings: settingsButton
        case .home: homeButton
        case .undo, .overflow: EmptyView()
        }
    }

    /// The layout for the current text size and undo history.
    func layout(for dynamicTypeSize: DynamicTypeSize) -> EditorToolbarLayout {
        EditorToolbarLayout(
            dynamicTypeSize: dynamicTypeSize,
            canUndo: undoManager?.canUndo ?? false,
            canRedo: undoManager?.canRedo ?? false)
    }

    /// The iPhone editing bar: compact width, the editing phase.
    var isCompactEditing: Bool {
        documentState.phaseKind == .editing && horizontalSizeClass == .compact
    }

    // MARK: - Toolbar Components

    /// Mark Whole Page in the overflow: the page bar's own toggle on the
    /// page in view. It shows for every page count; the page bar's
    /// control is hidden on a one-page document.
    /// The row reads Mark Whole Page, or Unmark Whole Page with its check on
    /// a marked page — the page bar's words, through its one label static.
    @ViewBuilder
    private var markWholePageButton: some View {
        let marked = PageNavigationBar.isWholePageMarked(
            page: documentState.currentPageIndex, in: redactionState)
        Toggle(isOn: Binding(get: { marked }, set: { _ in toggleWholePage() })) {
            Label(PageNavigationBar.wholePageActionLabel(marked: marked), systemImage: "rectangle.inset.filled")
        }
        .accessibilityIdentifier("overflowMarkWholePage")
    }

    /// The overflow row's action — `PageNavigationBar.toggleWholePage`, the
    /// one home of the whole-page region.
    func toggleWholePage() {
        PageNavigationBar.toggleWholePage(
            redactionState: redactionState, documentState: documentState, undoManager: undoManager)
    }

    /// The one Undo control: a tap undoes, a touch and hold opens Undo and
    /// Redo named for their steps ("Undo Add Region"). With nothing to undo
    /// but a step to redo, a tap opens the menu; with neither it is off.
    /// The menu's rows are built when it opens, so their names are fresh;
    /// their ⌘Z and ⇧⌘Z stay registered while it is closed. The undo
    /// history is not observable, so the control reads the region version
    /// — every undoable editor step changes the regions — to re-evaluate.
    @ViewBuilder
    var undoControl: some View {
        let _ = redactionState.regionVersion
        let mode = EditorToolbarLayout.undoMode(
            canUndo: undoManager?.canUndo ?? false, canRedo: undoManager?.canRedo ?? false)
        Group {
            if mode == .tapUndoesHoldOpensMenu {
                Menu { undoRows } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                } primaryAction: {
                    undoManager?.undo()
                }
            } else {
                Menu { undoRows } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
            }
        }
        .menuOrder(.fixed)
        .disabled(mode == .unavailable)
        .accessibilityHint(EditorToolbarLayout.undoHint(for: mode))
        .accessibilityIdentifier("undoButton")
    }

    @ViewBuilder
    private var undoRows: some View {
        Button(undoManager?.undoMenuItemTitle ?? "Undo", systemImage: "arrow.uturn.backward") {
            undoManager?.undo()
        }
        .disabled(!(undoManager?.canUndo ?? false))
        .keyboardShortcut("z", modifiers: .command)

        Button(undoManager?.redoMenuItemTitle ?? "Redo", systemImage: "arrow.uturn.forward") {
            undoManager?.redo()
        }
        .disabled(!(undoManager?.canRedo ?? false))
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .accessibilityIdentifier("redoButton")
    }

    @ViewBuilder
    private var deleteButton: some View {
        let count = redactionState.selectedRegionIDs.count
        if count > 0 {
            // Deletes at once, any count, through the one delete rule.
            Button(deleteButtonLabel, systemImage: "trash") { deleteSelection() }
            .tint(.red)
            // Command-Delete: a bare Delete key belongs to the text field it edits.
            .keyboardShortcut(.delete, modifiers: [.command])
        }
    }

    // "Select More" toolbar toggle. While on, a tap on a region
    // adds to selection rather than replacing it — iPhone parity for
    // the iPad Shift+tap path. Visible only when the current page has
    // regions to select; it turns off on a page with none.
    @ViewBuilder
    private var selectMoreToggle: some View {
        let page = documentState.currentPageIndex
        if (redactionState.regions[page]?.count ?? 0) > 0 {
            // A Toggle row: its own On/Off state is the value VoiceOver
            // reads. Mutual exclusion with the Rectangle tool: whichever
            // was turned on last wins.
            Toggle(isOn: Binding(
                get: { isMultiSelectActive },
                set: { on in
                    isMultiSelectActive = on
                    if isMultiSelectActive { activeTool = nil }
                }
            )) {
                Label(RedactionOverlayView.selectMoreToggleTitle, systemImage: "checkmark.square")
            }
            // Teal only while on: the Redact button stays the one brand-tint
            // literal in the toolbar.
            .tint(isMultiSelectActive ? ResectaTokens.BrandTeal.tint : nil)
            .accessibilityIdentifier("selectMoreToggle")
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
                    redactionState.selectAllOnPage(page)
                }
                .disabled(!redactionState.canSelectAllOnPage(page))
                if selectedCount > 0 {
                    Button("Deselect All", systemImage: "xmark.circle") {
                        redactionState.deselectAllRegions()
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

    /// The … menu's Delete and ⌘⌫: the one delete rule (its notice for
    /// several), then Add to Selection ends through the one reset.
    func deleteSelection() {
        let outcome = RegionDeleteRule.deleteSelection(
            redactionState: redactionState, undoManager: undoManager, toastManager: coordinator.toastManager)
        if outcome.endsAddToSelection { resetCanvasTools() }
    }

    /// The delete's words, shared by the toolbar and the long-press menu.
    static func deleteLabel(count: Int) -> String {
        count > 1 ? "Delete \(count) Regions" : "Delete Region"
    }

    var deleteButtonLabel: String {
        Self.deleteLabel(count: redactionState.selectedRegionIDs.count)
    }
}

/// The editor's toolbar content. On iPhone in the editing phase the trailing
/// side is the layout's pieces — the Undo control, Redact, the system … —
/// each its own item with a fixed spacer between, and the inline title is
/// hidden (the bar leaves it no room); every other case keeps the trailing
/// group. The neutral tint is applied inside each item's view, never
/// chained in this builder.
struct EditorToolbarContent: ToolbarContent {
    let toolbar: DocumentEditorToolbar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            toolbar.leadingToolbarItems
        }
        if toolbar.isCompactEditing {
            let layout = toolbar.layout(for: dynamicTypeSize)
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            }
            ToolbarItem(placement: .topBarTrailing) {
                toolbar.undoControl.tint(.primary)
            }
            if layout.trailing.contains(.redact) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    toolbar.redactButton
                        .buttonStyle(.glassProminent)
                        .labelStyle(.iconOnly)
                }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItemGroup(placement: .secondaryAction) {
                toolbar.secondaryActionToolbarItems(layout: layout)
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                toolbar.trailingToolbarItems
            }
        }
    }
}
