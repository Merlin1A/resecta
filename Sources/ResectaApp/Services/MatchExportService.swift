import UIKit

// The topmost presented view controller, for the share sheets the
// editor presents over the search sheet.

enum MatchExportService {
    /// Resolve the topmost presented view controller for modally-attached
    /// sheets (the active scene's rootViewController is usually covered
    /// by the Search sheet itself).
    @MainActor
    static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
            let root = scene.keyWindow?.rootViewController else {
            return nil
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
