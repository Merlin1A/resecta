import SwiftUI

// SEC-3 extension: sheet-level capture shield.
//
// Modal presentation renders ABOVE `DocumentEditorView`'s shield swap, so
// the existing SEC-3 shield does not cover the Search & Redact or Detection
// Triage sheets — the two most PII-dense surfaces in the app. This shared
// modifier swaps the sheet's entire content for `PrivacyShieldView` while
// `ScreenCaptureMonitor.isShielded` is set, mirroring the editor-level swap.
//
// INJECTION PATTERN (decided 2026-06-10): the monitor arrives as a `let`,
// NOT an @Environment read inside `body` — the toast dismiss-crash incident
// (ToastView's `@Environment(ToastQueueManager.self)` asserting during a
// dismiss-coincident re-layout, fixed in 37b56c9 by let-injection) is the
// precedent, and sheet dismissal is exactly the layout window this modifier
// lives in. Call sites obtain the monitor once via @Environment at the
// SHEET level (a stable container view) and pass it down as a value.

struct ShieldedSheetContent: ViewModifier {
    let captureMonitor: ScreenCaptureMonitor

    /// Pure decision seam pinned by `ScreenCaptureShieldTests` — the same
    /// "static contract, testable without rendering" pattern as
    /// `DetectionTriageSheet.triageSelections(rewritingFor:in:)`.
    static func shouldShield(_ monitor: ScreenCaptureMonitor) -> Bool {
        monitor.isShielded
    }

    func body(content: Content) -> some View {
        if Self.shouldShield(captureMonitor) {
            PrivacyShieldView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
        }
    }
}

extension View {
    /// Swap this sheet's content for the SEC-3 `PrivacyShieldView` while a
    /// screen capture / mirroring signal is active. Apply at the outermost
    /// level of a sheet's `body` so no sensitive subview survives the swap.
    func shieldedSheetContent(monitor: ScreenCaptureMonitor) -> some View {
        modifier(ShieldedSheetContent(captureMonitor: monitor))
    }
}
