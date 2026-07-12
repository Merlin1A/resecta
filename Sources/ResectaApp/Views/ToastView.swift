import SwiftUI

// §A6.3: Severity-aware toast capsule with tint overlay and position-based animation.
// Displayed via dual-position overlays in ContentView (§A6.7).
//
// WU-19 (session-8): renders an optional trailing action button when
// `item.actionLabel` is set. Tapping the button invokes
// `item.actionHandler` (the snapshot closure) and then dismisses the
// toast through the injected `ToastQueueManager`. Per [RR-23], the
// closure captures the snapshot state and expires when the toast
// dismisses.

struct ToastView: View {
    let item: ToastItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // ACCESSIBILITY.md §9.3 — toast line cap lifts at AX5 so long messages
    // don't truncate mid-sentence at the largest accessibility text size.
    // Mirrors the `InlineWarningBanner.lineLimit(for:)` pattern.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // Injected by ContentView (the owner), NOT read via
    // `@Environment(ToastQueueManager.self)`: when a `toastVersion` change
    // re-evaluates this body inside the synchronous transaction the ContentView
    // toast overlay's `.animation(value:)` flushes during a coincident sheet
    // dismissal, the observable-object environment lookup can't resolve and
    // traps (EXC_BREAKPOINT — the strict-Observation "state during update"
    // assertion). Passing it in sidesteps that read. Structural guard:
    // ToastManagerLetInjectionTests (asserts this stays a `let`, never an
    // `@Environment(ToastQueueManager.self)` read); crash-path guard:
    // DetectionTriageDismissUITests.
    let toastManager: ToastQueueManager

    var body: some View {
        HStack(spacing: ResectaTokens.Spacing.sm) {
            Image(systemName: item.severity.sfSymbol)
                .foregroundStyle(item.severity.tintColor)
                .frame(width: 20, height: 20)

            Text(item.message)
                .font(.callout.weight(.medium))
                .lineLimit(Self.toastLineLimit(
                    severity: item.severity,
                    dynamicTypeSize: dynamicTypeSize
                ))

            if let actionLabel = item.actionLabel,
               let actionHandler = item.actionHandler {
                Spacer(minLength: ResectaTokens.Spacing.xs)
                Button {
                    actionHandler()
                    toastManager.dismiss(item)
                } label: {
                    Text(actionLabel)
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(item.severity.tintColor)
                .accessibilityLabel("\(actionLabel) action")
            }
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.toastVertical)
        .containerRelativeFrame(.horizontal) { length, _ in
            min(length - 32, 360)
        }
        .background {
            // Research Area 9: rounded rectangle with severity tinting
            ZStack {
                RoundedRectangle(cornerRadius: ResectaTokens.CornerRadius.toast,
                                 style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: ResectaTokens.CornerRadius.toast,
                                 style: .continuous)
                    .fill(item.severity.tintColor.opacity(ResectaTokens.Opacity.severityTint))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    /// ACCESSIBILITY.md §9.3 — toast line cap predicate. Below AX5, error
    /// and warning toasts cap at 2 lines and info/success cap at 1 line per
    /// the §A6.3 compact-capsule contract. At `.accessibility5` or larger
    /// the cap lifts to 3 lines for all severities so multi-clause messages
    /// remain readable when the text size is at its accessibility maximum.
    /// Exposed as a `static` so the contract can be unit-tested without
    /// rendering the view (mirrors `InlineWarningBanner.lineLimit(for:)`).
    static func toastLineLimit(
        severity: ToastSeverity,
        dynamicTypeSize: DynamicTypeSize
    ) -> Int {
        if dynamicTypeSize >= .accessibility5 {
            return 3
        }
        return (severity == .error || severity == .warning) ? 2 : 1
    }
}
