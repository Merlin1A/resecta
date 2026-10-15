import Foundation

// The per-page fold the Character Count and Font Verification dispatchers
// share: a verifier call's per-page outcomes are collected the way Layer 6
// collects its pages — every failing page behind the first FAIL message,
// else every warned page behind the first WARN message — so a per-page
// warning reaches the layer instead of being dropped on the way to PASS.
// Whether the warning means the check did not fully run is the layer's
// call: Layer 8's two warnings do (a font it could not inspect, a page
// with no page-level resources); Layer 7's count excess is a note.

extension VerificationEngine {

    /// The per-page outcomes of one verifier call, folded in page order.
    struct PerPageOutcomes {
        private(set) var failingPages: [Int] = []
        private(set) var firstFailMessage: String?
        private(set) var warnedPages: [Int] = []
        private(set) var firstWarnMessage: String?

        /// Record one page's outcome; PASS and the other cases add nothing.
        mutating func record(_ status: VerificationStatus, page: Int) {
            switch status {
            case .fail(let message):
                failingPages.append(page)
                if firstFailMessage == nil { firstFailMessage = message }
            case .warn(let message):
                warnedPages.append(page)
                if firstWarnMessage == nil { firstWarnMessage = message }
            default:
                break
            }
        }

        /// The layer's FAIL with every failing page, when any page failed.
        var failure: (VerificationStatus, [Int]?, Bool)? {
            firstFailMessage.map { (.fail($0), failingPages, false) }
        }

        /// The layer's WARN with every warned page, when any page warned;
        /// `couldNotVerify` says whether the warning means the check did not
        /// fully run on those pages.
        func warning(couldNotVerify: Bool) -> (VerificationStatus, [Int]?, Bool)? {
            firstWarnMessage.map { (.warn($0), warnedPages, couldNotVerify) }
        }
    }
}
