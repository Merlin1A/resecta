import Foundation

/// How to interpret the search query.
public enum SearchMode: Sendable {
    case text(String, options: SearchOptions)
    case regex(String, options: SearchOptions)
    case multiTerm([String], options: SearchOptions)
    /// Auto-detect PII patterns across the document.
    /// Only categories in the set are scanned; pass PIICategory.allCases for full scan.
    case piiScan(categories: Set<PIICategory>, options: SearchOptions)
}
