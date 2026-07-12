import Foundation

/// Lightweight structural finding from PDF analysis primitives.
/// Used by PDFByteScanner, PDFStructureReader, and AnnotationAnalyzer
/// for reporting structural observations without coupling to audit-specific types.
public struct PDFFinding: Sendable, Identifiable {
    public let id: String
    /// Mechanism-description language ONLY (ARCH 1.3).
    public let summary: String
    public let detail: String?
    public let severity: Severity
    /// nil = document-level finding. Non-nil = page-specific.
    public let pageIndices: [Int]?

    public enum Severity: Sendable { case info, warning, critical }

    public init(id: String, summary: String, detail: String? = nil,
                severity: Severity, pageIndices: [Int]? = nil) {
        self.id = id; self.summary = summary; self.detail = detail
        self.severity = severity; self.pageIndices = pageIndices
    }
}

/// Result of a known-terms binary search across raw PDF bytes.
public struct KnownTermsSearchResult: Sendable {
    public let termsSearched: Int
    public let termsFound: Int

    public init(termsSearched: Int, termsFound: Int) {
        self.termsSearched = termsSearched
        self.termsFound = termsFound
    }
}
