import SwiftUI

// GAP §4.4: Reusable filter/selection chip — the one chip component for
// the unified review surface's chip rows (pre-scan detector selection,
// post-scan category filters, review-mode kind filters).

struct FilterChip: View {
    let label: String
    let count: Int?
    /// Optional leading SF Symbol (category chips carry their
    /// category glyph; plain chips render text-only).
    let systemImage: String?
    /// Optional per-chip accent (category chips keep their category
    /// color coding). nil renders the ambient `.tint` styling the chip
    /// always had.
    let tint: Color?
    let isSelected: Bool
    let action: () -> Void

    init(
        label: String,
        count: Int? = nil,
        systemImage: String? = nil,
        tint: Color? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.count = count
        self.systemImage = systemImage
        self.tint = tint
        self.isSelected = isSelected
        self.action = action
    }

    private var strokeStyle: AnyShapeStyle {
        if isSelected {
            return tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint)
        }
        return tint != nil
            ? AnyShapeStyle(.secondary.opacity(0.3))
            : AnyShapeStyle(.quaternary)
    }

    private var fillStyle: AnyShapeStyle {
        guard isSelected else { return AnyShapeStyle(.clear) }
        return tint.map { AnyShapeStyle($0.opacity(0.2)) }
            ?? AnyShapeStyle(.tint.opacity(0.15))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: ResectaTokens.Spacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2)
                }
                Text(label)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                if let count {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(isSelected && tint == nil
                            // CD-4: ambient accent measures 4.01 as small text
                            // on the selected wash - below the 4.5 small-text
                            // floor; the text tier holds 6.18 worst. The
                            // teal text tier is validated against the ambient
                            // wash only, so tinted chips keep the neutral
                            // secondary count.
                            ? AnyShapeStyle(ResectaTokens.BrandTeal.text)
                            : AnyShapeStyle(.secondary))
                }
            }
            // REV-01 (packet §7.2 item 1, RB-66): compact drawn
            // capsule — 36pt drawn height (a minimum: Dynamic Type
            // text growth raises it), 12pt horizontal padding (the
            // board's one proportion change from the old 8), natural
            // width. RB-67: the UXC-18 46pt floor moves AFTER the
            // background chain as a pure LAYOUT frame + contentShape —
            // the hit area still clears the HIG effective minimum
            // (RB-54 held) while the capsule draws at chip scale. Hit
            // expansion beyond the layout frame is banned, so sibling
            // hit zones can never overlap.
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(fillStyle, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        strokeStyle,
                        lineWidth: ResectaTokens.Border.subtle
                    )
            )
            .frame(
                minWidth: ResectaTokens.TouchTarget.minimum,
                minHeight: ResectaTokens.TouchTarget.minimum
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected) // §4.6: haptic on filter toggle
    }
}
