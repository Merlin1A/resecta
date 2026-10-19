import Foundation

// G5 "Why this classification?" diagnostic. In-memory only — never logged,
// never persisted. Released on `clearAll()`.

public struct ClassificationDiagnostic: Sendable, Equatable {
    public let primary: DoctypeClass
    public let runnerUp: DoctypeClass?
    public let softmaxSnapshot: [DoctypeClass: Double]
    public let topKeywords: [DoctypeResult.TopKeyword]

    public init(
        primary: DoctypeClass,
        runnerUp: DoctypeClass?,
        softmaxSnapshot: [DoctypeClass: Double],
        topKeywords: [DoctypeResult.TopKeyword]
    ) {
        self.primary = primary
        self.runnerUp = runnerUp
        self.softmaxSnapshot = softmaxSnapshot
        self.topKeywords = topKeywords
    }

    /// Build from a fresh DoctypeResult, trimming to top-5 keywords.
    public init(from result: DoctypeResult) {
        self.primary = result.primary
        self.runnerUp = result.runnerUp
        self.softmaxSnapshot = result.softmax
        self.topKeywords = Array(result.topKeywords.prefix(5))
    }
}
