import Foundation

/// Single Identifiable enum that drives the consolidated
/// `.sheet(item:)` on `SearchAndRedactSheet`. Replaces four overlapping
/// modifiers (two `.sheet`s, one `.popover`, one `.sheet(item:)`) whose
/// boolean and item-driven bindings could fight over UIKit's
/// single-modal-presenter contract on the hosting view controller.
/// The consolidation also absorbs the per-row rationale sheet as
/// `.rowRationale`; the row signals via an `onRequestShowRationale`
/// callback instead of holding its own `@State`.
enum SearchModal: Identifiable {
    case rationale(ReverseRationaleRequest)
    case rowRationale(rowID: UUID)
    /// Saved-searches recall list.
    case savedSearches
    /// The notice place's details.
    case noticeDetails

    var id: String {
        switch self {
        case .rationale(let request): return "rationale.\(request.id)"
        case .rowRationale(let rowID): return "rowRationale.\(rowID)"
        case .savedSearches: return "savedSearches"
        case .noticeDetails: return "noticeDetails"
        }
    }
}
