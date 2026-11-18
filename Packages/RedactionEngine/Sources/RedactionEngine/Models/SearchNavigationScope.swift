import Foundation

/// Session-scoped scope for Cmd+G / J / K traversal.
public enum SearchNavigationScope: String, CaseIterable, Sendable, Equatable {
    case currentPage
    case wholeDocument
}
