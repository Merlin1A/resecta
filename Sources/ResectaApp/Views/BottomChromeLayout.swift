import SwiftUI

// The bottom-chrome layout model — ONE pure value behind the iPhone page
// bar, the parked-canvas inset, both bottom toast hosts and the
// drawing-mode hint capsule. The three predicates that used to re-derive
// the parked geometry (`pageBarCompactInset`, `compactParkedCanvasInset`,
// `toastBottomClearance`) collapse into this value. While a result walk
// is live at the compact float the page bar steps aside: the walk owns
// paging there (the strip's ‹ › step between hits, across pages), and a
// page with no hits is reached by scrolling or by raising the sheet. The
// bar stays when the sheet is parked with no walk (the draw tests' park),
// and is back behind a taller sheet and once the walk ends.
//
// Inputs are the editor's own reads (the sheet slot, the detent
// binding, the published walk liveness, the document's page count and
// phase, the size class) plus the hug the detent reports for the
// current type size — `CompactFloatDetent.hug(for:)`, never the bare
// constant, so the insets and the toast clearance move with the AX
// hug. Pure and `Equatable`: `ParkedChromeLayoutTests` pins the truth
// table without a SwiftUI host.

struct ParkedChromeLayout: Equatable {
    /// The page bar's own layout height — the chevrons' 46-pt floor
    /// plus the bar's vertical padding (`PageNavigationBar`). A bottom
    /// toast clears the bar by this much while the bar is up and no
    /// taller sheet covers it (the import toast used to sit over it).
    static let pageBarClearance: CGFloat =
        ResectaTokens.TouchTarget.minimum + 2 * ResectaTokens.Spacing.sm

    /// Whether the iPhone page bar mounts: compact width, a document
    /// open (one page included, for its region count), the editing
    /// phase, and no result walk parked at the compact float.
    let showsPageBar: Bool
    /// The bottom safe-area inset under the page bar, or the bare inset
    /// when no bar mounts: the hug while the sheet is parked, else 0.
    /// Zoomed content structurally cannot sit under the float.
    let canvasBottomInset: CGFloat
    /// How far the bottom toast hosts lift: the hug while parked, plus
    /// the page bar's height while the bar is up and uncovered. Zero
    /// with the sheet up at a taller detent — the sheet-local host
    /// renders inside the sheet then, and the app-level copy is
    /// covered.
    let toastClearance: CGFloat
    /// Extra lift for the drawing-mode hint capsule above its `lg`
    /// padding. The capsule rides the bottom safe-area inset (the bar
    /// or the bare parked inset), so it already clears the strip in
    /// every state; the seam is here for the day that changes.
    let hintCapsuleLift: CGFloat

    init(
        sheetPresented: Bool,
        detent: PresentationDetent,
        walkLive: Bool,
        pageCount: Int,
        sizeClass: UserInterfaceSizeClass?,
        phase: DocumentState.PhaseKind,
        hugHeight: CGFloat
    ) {
        let parked = sheetPresented && detent == .compactFloat
        let barEligible = sizeClass == .compact && pageCount >= 1 && phase == .editing
        showsPageBar = barEligible && !(parked && walkLive)
        canvasBottomInset = parked ? hugHeight : 0
        let barUncovered = showsPageBar && !(sheetPresented && !parked)
        toastClearance = (parked ? hugHeight : 0)
            + (barUncovered ? Self.pageBarClearance : 0)
        hintCapsuleLift = 0
    }
}
