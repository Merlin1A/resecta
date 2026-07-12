import SwiftUI

// GAP §4.4: Reusable filter chip for the triage filter bar.

struct FilterChip: View {
    let label: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    init(label: String, count: Int? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.label = label
        self.count = count
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: ResectaTokens.Spacing.xs) {
                Text(label)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                if let count {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(isSelected
                            // CD-4: ambient accent measures 4.01 as small text
                            // on the selected wash - below the 4.5 small-text
                            // floor; the text tier holds 6.18 worst.
                            ? AnyShapeStyle(ResectaTokens.BrandTeal.text)
                            : AnyShapeStyle(.secondary))
                }
            }
            .padding(.horizontal, ResectaTokens.Spacing.sm)
            .padding(.vertical, ResectaTokens.Spacing.xs)
            .background(
                isSelected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        lineWidth: ResectaTokens.Border.subtle
                    )
            )
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected) // §4.6: haptic on filter toggle
    }
}
