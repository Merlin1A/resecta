import SwiftUI

// Severity-aware toast capsule with tint overlay and position-based animation.
// Displayed via dual-position overlays in ContentView.
//
// Renders an optional trailing action button when
// `item.actionLabel` is set. Tapping the button invokes
// `item.actionHandler` (the snapshot closure) and then dismisses the
// toast through the injected `ToastQueueManager`. The
// closure captures the snapshot state and expires when the toast
// dismisses.

struct ToastView: View {
    let item: ToastItem
    // The toast line cap lifts at AX5 so long messages
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
        let layout = Self.layout(for: dynamicTypeSize)
        // The icon scales with the message (the same text style) and
        // sits on the text's first baseline inside a MINIMUM frame:
        // the former fixed 20-pt box let the glyph grow over its own
        // edge onto the first character at accessibility sizes. At the
        // accessibility sizes the icon stacks above the text instead, so
        // every line gets the toast's full width (beside the icon, a
        // two-sentence toast at AX5 ran past the screen).
        return layout {
            Image(systemName: item.severity.sfSymbol)
                .font(Self.toastIconFont)
                .foregroundStyle(item.severity.tintColor)
                .frame(minWidth: Self.toastIconMinimumSide,
                       minHeight: Self.toastIconMinimumSide)

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
            // Rounded rectangle with severity tinting
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

    /// The toast's layout: the icon beside the text at the standard
    /// sizes, above it at the accessibility sizes (pinned by
    /// `AccessibilityLabelTests`).
    static func stacksIconAboveText(_ size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    private static func layout(for size: DynamicTypeSize) -> AnyLayout {
        stacksIconAboveText(size)
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ResectaTokens.Spacing.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: ResectaTokens.Spacing.sm))
    }

    /// Toast line cap predicate. At the standard sizes every
    /// severity caps at 2 lines. The original compact-capsule
    /// contract held info/success to 1 line, but real shipped messages
    /// exceed one capsule line at standard text sizes (the text-layer
    /// notice and the dismissal-cleared counts truncated mid-sentence),
    /// so the info/success baseline was raised to the warning/error cap.
    /// At the accessibility sizes there is no cap: the toast grows to its
    /// text, so a two-sentence message keeps the sentence that says what
    /// to do. `severity` stays in the
    /// signature so the per-severity contract remains directly
    /// assertable. Exposed as a `static` so the contract can be
    /// unit-tested without rendering the view (mirrors
    /// `InlineWarningBanner.lineLimit(for:)`).
    /// The icon's text style — the message's own, so both scale
    /// together — and the floor its frame never shrinks under (the
    /// former fixed box, now a minimum). Pinned by
    /// `AccessibilityLabelTests`.
    static let toastIconFont: Font = .callout.weight(.medium)
    static let toastIconMinimumSide: CGFloat = 20

    static func toastLineLimit(
        severity: ToastSeverity,
        dynamicTypeSize: DynamicTypeSize
    ) -> Int? {
        // No cap at the accessibility sizes: at AX3 a two-sentence toast
        // needs well over three lines, and the second sentence is the one
        // that says what to do. The toast grows to its text; its display
        // time already scales with its words. The standard sizes keep two.
        if dynamicTypeSize.isAccessibilitySize {
            return nil
        }
        return 2
    }
}
