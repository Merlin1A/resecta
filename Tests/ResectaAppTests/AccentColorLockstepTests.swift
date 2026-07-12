import Testing
import SwiftUI
import UIKit
@testable import ResectaApp

// q40 / CD-19 — one-source-of-truth guard for the brand tint. The teal pair
// is unavoidably duplicated: once in the AccentColor colorset (system chrome,
// NSAccentColorName) and once in ResectaTokens.BrandTeal.tint (the root
// ambient .tint — the iOS 26.4 sim runtime does not adopt the colorset as
// the global tint, so both sources ship). This suite pins the two sources
// component-equal in BOTH appearances so they cannot drift, and the named
// lookup doubles as built-app packaging proof for the colorset (M-8 spirit;
// resolved against the APP bundle via Bundle(for:), same rationale as
// BundleContentsTests — a Bundle.main pointing at the xctest runner cannot
// produce a false green).

@Suite("AccentColor colorset ↔ BrandTeal.tint lockstep (q40/CD-19)")
struct AccentColorLockstepTests {

    private var appBundle: Bundle { Bundle(for: AppCoordinator.self) }

    @Test("Colorset matches BrandTeal.tint in light and dark", arguments: [
        UIUserInterfaceStyle.light, UIUserInterfaceStyle.dark
    ])
    func colorsetMatchesToken(style: UIUserInterfaceStyle) throws {
        let trait = UITraitCollection(userInterfaceStyle: style)
        let colorset = try #require(
            UIColor(named: "AccentColor", in: appBundle, compatibleWith: trait),
            "AccentColor.colorset missing from the app bundle — the catalog's project.yml sources: entry is gone or the colorset was removed"
        )
        let token = UIColor(ResectaTokens.BrandTeal.tint).resolvedColor(with: trait)

        var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        #expect(colorset.resolvedColor(with: trait).getRed(&cr, green: &cg, blue: &cb, alpha: &ca))
        #expect(token.getRed(&tr, green: &tg, blue: &tb, alpha: &ta))

        // Component equality within 1/255 — both sides are authored as sRGB
        // 8-bit hex; the tolerance only absorbs float rounding, not a
        // different color.
        let tolerance: CGFloat = 1.0 / 255.0
        #expect(abs(cr - tr) <= tolerance, "red drifted (\(style == .dark ? "dark" : "light"))")
        #expect(abs(cg - tg) <= tolerance, "green drifted (\(style == .dark ? "dark" : "light"))")
        #expect(abs(cb - tb) <= tolerance, "blue drifted (\(style == .dark ? "dark" : "light"))")
        #expect(abs(ca - ta) <= tolerance, "alpha drifted (\(style == .dark ? "dark" : "light"))")
    }
}
