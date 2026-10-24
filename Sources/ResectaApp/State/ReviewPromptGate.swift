import Foundation
import RedactionEngine

// When the app asks for an App Store rating: once per app version, after
// the first completed share of a document whose checks passed. A share
// whose checks reported issues, did not run in full or were skipped never
// asks, and an error or a refusal never reaches a completed share. The one
// stored value is the version that last asked.

nonisolated struct ReviewPromptGate {
    /// The stored version string that last asked.
    static let askedVersionKey = "reviewPrompt.askedVersion.v1"

    let defaults: UserDefaults
    let appVersion: String

    /// The gate over the app's own defaults and marketing version.
    static var standard: ReviewPromptGate {
        ReviewPromptGate(
            defaults: .standard,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        )
    }

    /// Checks that read as passed on the results screen.
    static func passed(_ status: VerificationStatus) -> Bool {
        switch status {
        case .pass, .info, .notApplicable: true
        case .warn, .attention, .fail, .skipped: false
        }
    }

    /// Whether a completed share of a report with `status` asks now. A
    /// `true` answer records this version, so the next share does not ask.
    func shouldAsk(afterSharing status: VerificationStatus) -> Bool {
        guard Self.passed(status) else { return false }
        guard defaults.string(forKey: Self.askedVersionKey) != appVersion else { return false }
        defaults.set(appVersion, forKey: Self.askedVersionKey)
        return true
    }
}
