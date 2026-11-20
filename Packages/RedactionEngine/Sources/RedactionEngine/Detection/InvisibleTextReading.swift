import CoreGraphics

/// What a page's content says about text shown in an invisible render mode
/// (3 or 7), from one walk of its content (`DocumentSearcher.invisibleTextReading`).
/// The yes-or-no fact the ink fit's gate and the box rule read is "anything
/// but `showsNone`"; a Searchable run's page mode reads all three.
enum InvisibleTextReading: Sendable, Equatable {
    /// A text-showing operator runs while the render mode is 3 or 7.
    case shows
    /// The whole content was read, and none does.
    case showsNone
    /// Some of the content could not be read: a content stream the scanner
    /// cannot read, a form chain past the depth limit, or the page's
    /// dictionary or resources.
    case unreadable

    /// The reading for one page: its dictionary and inherited resources
    /// first, then the walk.
    static func read(_ page: CGPDFPage?) -> InvisibleTextReading {
        guard let page, let dictionary = page.dictionary else { return .unreadable }
        if case .unreadable = TextLayerExtractor.inheritedResources(of: dictionary) { return .unreadable }
        return DocumentSearcher.invisibleTextReading(page)
    }
}
