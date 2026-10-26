import Foundation

/// The first-launch sequence: the agreement gate, then the app. Pure, so the
/// order is testable without a scene.
///
/// The agreement key is versioned: bumping it re-prompts everyone who
/// accepted an earlier version.
enum FirstLaunchFlow {

    /// The UserDefaults key recording acceptance of the CURRENT terms.
    /// `ResectaApp` and `EULAGateView` both read it through this constant.
    static let agreementKey = "disclaimerAccepted_v2"

    /// Earlier agreement keys, oldest first. Accepting the current terms
    /// removes these so a bump does not orphan stale flags in UserDefaults.
    /// `_v1` shipped in 1.0.0 through 1.2.0.
    static let supersededAgreementKeys = ["disclaimerAccepted_v1"]

    enum Screen: Equatable {
        case agreement
        case app
    }

    static func screen(agreementAccepted: Bool) -> Screen {
        agreementAccepted ? .app : .agreement
    }
}
