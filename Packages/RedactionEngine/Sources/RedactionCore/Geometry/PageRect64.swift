/// A rectangle on a page in whole sixty-fourths of a point.
///
/// Coordinates are in the page's frame as it is rasterised (after its quarter
/// turn), with the origin at the page's bottom-left corner. Whole numbers make
/// equality exact: two pieces of code that read the same rectangle cannot
/// round it differently. An edge may lie off the page; nothing here clips.
package struct PageRect64: Hashable, Sendable {
    package var minX: Int
    package var minY: Int
    package var maxX: Int
    package var maxY: Int

    package init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    package var width: Int { maxX - minX }
    package var height: Int { maxY - minY }

    /// Whether the rectangle has no area: a side of zero length or less.
    package var isEmpty: Bool { maxX <= minX || maxY <= minY }
}
