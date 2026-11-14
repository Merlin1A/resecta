import Foundation

/// Where the match was found.
public enum SearchSource: Sendable, Equatable {
    case textLayer
    case ocr(confidence: Float)
}

// A re-check request hashes the results the user left unselected.
extension SearchSource: Hashable {}
