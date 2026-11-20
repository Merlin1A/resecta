import SwiftUI

/// The text size a brief message is drawn at.
///
/// A message is drawn at the person's text size if its height is within
/// 40 % of the space it is read in ("within" is at or under). If it is not
/// and the person's size is above the third accessibility size, it is drawn
/// at the first size, from theirs down to the third accessibility size, at
/// which it is within the limit; if none is, at the third, over the limit.
/// At the third accessibility size or below it is drawn at the person's
/// size whatever its height.
///
/// The space and the height of a message at each size are the caller's:
/// nothing here knows a view or a screen's measure.
// nonisolated: pure arithmetic over values, callable from any isolation.
nonisolated enum MessageSizing {

    /// The share of the space a message may take before it is drawn smaller.
    static let readableShare: CGFloat = 0.4

    /// The smallest size a message is stepped down to.
    static let typeFloor: DynamicTypeSize = .accessibility3

    /// The tallest a message may be in `space` points: 40 % of it.
    static func limit(space: CGFloat) -> CGFloat {
        space * readableShare
    }

    /// The size to draw at, for the person's size, the limit from
    /// `limit(space:)` and the message's height at a given size.
    static func drawSize(
        person: DynamicTypeSize,
        limit: CGFloat,
        height: (DynamicTypeSize) -> CGFloat
    ) -> DynamicTypeSize {
        guard person > typeFloor else { return person }
        let steps = DynamicTypeSize.allCases
            .filter { $0 >= typeFloor && $0 <= person }
            .sorted(by: >)
        for size in steps where height(size) <= limit {
            return size
        }
        return typeFloor
    }
}
