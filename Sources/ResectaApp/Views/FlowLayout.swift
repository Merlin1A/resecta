import SwiftUI

// GAP-4 §7.3: Horizontal flow layout for page reference chips.
// Chips wrap to the next line when they exceed available width.

struct FlowLayout: Layout {
    var spacing: CGFloat
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrangeSubviews(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity

        // First pass: group subviews into rows and record per-row width.
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var currentIndices: [Int] = []
        var currentWidth: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var sizes: [CGSize] = []

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            sizes.append(size)
            let candidateWidth = currentIndices.isEmpty ? size.width : currentWidth + spacing + size.width
            if candidateWidth > maxWidth && !currentIndices.isEmpty {
                rows.append((currentIndices, currentWidth, currentRowHeight))
                currentIndices = [index]
                currentWidth = size.width
                currentRowHeight = size.height
            } else {
                currentIndices.append(index)
                currentWidth = candidateWidth
                currentRowHeight = max(currentRowHeight, size.height)
            }
        }
        if !currentIndices.isEmpty {
            rows.append((currentIndices, currentWidth, currentRowHeight))
        }

        // Second pass: place subviews, applying horizontal alignment per row.
        var positions: [CGPoint] = Array(repeating: .zero, count: subviews.count)
        var y: CGFloat = 0
        for row in rows {
            let rowOffset: CGFloat
            switch alignment {
            case .center:
                rowOffset = max(0, (maxWidth - row.width) / 2)
            case .trailing:
                rowOffset = max(0, maxWidth - row.width)
            default:
                rowOffset = 0
            }
            var x: CGFloat = rowOffset
            for index in row.indices {
                positions[index] = CGPoint(x: x, y: y)
                x += sizes[index].width + spacing
            }
            y += row.height + spacing
        }
        let totalHeight = y - (rows.isEmpty ? 0 : spacing)

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}
