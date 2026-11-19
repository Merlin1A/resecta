import Foundation

extension SearchAndRedactSheet {
    /// Whether Search's content leaving the screen ends its session: true
    /// only when the session is neither parked for the Home close dialog
    /// nor covered by the screen-capture cover. Search's session ends when
    /// the sheet is dismissed or a run starts; when its content leaves
    /// because the cover replaced it, nothing of the session is torn down.
    /// A pure decision, testable without rendering (the same form as
    /// `ShieldedSheetContent.shouldShield`).
    static func contentLeavingTearsDown(parked: Bool, covered: Bool) -> Bool {
        !parked && !covered
    }
}
