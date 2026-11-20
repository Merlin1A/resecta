import SwiftUI
import UIKit

extension ResectaTokens {
    /// Colours of the message surfaces: the dark capsule, the notice and
    /// the asking sheets. A mark on them is a glyph, and the status text
    /// tier is for text only, so each mark here has two values of its own.
    // nonisolated: pure colour constants, usable from any isolation, as the
    // tokens file's own colour groups are; a test's arguments read them.
    nonisolated enum Ink {
        /// The caution mark. Light #9A5B00 · Dark #FF9F0A.
        /// By arithmetic: 5.43:1 on white and 4.86:1 on the grouped
        /// background (#F2F2F7) in light; 8.28:1 on #1C1C1E and 6.78:1 on
        /// #2C2C2E in dark. A mark needs 3:1.
        static let cautionMark: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0xFF/255, green: 0x9F/255, blue: 0x0A/255, alpha: 1)
                    : UIColor(red: 0x9A/255, green: 0x5B/255, blue: 0x00/255, alpha: 1)
            }
        )

        // The names below are read under the content's colour scheme, which
        // is the opposite of the app's appearance: on the dark capsule of the
        // light appearance a name gives its dark value, on the light capsule
        // of the dark appearance its light value, on a sheet the sheet's own.
        // Two names take the app's appearance instead, and say so:
        // `surface(for:increasedContrast:)` and `shadows(for:)`.

        /// The stop mark. Light #C2262E · Dark #FF7A72. Drawn as the stop
        /// tone's glyph on the message surfaces. Contrast on the capsule:
        /// not measured.
        static let stopMark: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0xFF/255, green: 0x7A/255, blue: 0x72/255, alpha: 1)
                    : UIColor(red: 0xC2/255, green: 0x26/255, blue: 0x2E/255, alpha: 1)
            }
        )

        /// The note mark. Light #111214 at 0.72 · Dark #FFFFFF at 0.82.
        /// Drawn as the note tone's glyph on the message surfaces. Contrast
        /// on the capsule: not measured.
        static let noteMark: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0xFF/255, green: 0xFF/255, blue: 0xFF/255, alpha: 0.82)
                    : UIColor(red: 0x11/255, green: 0x12/255, blue: 0x14/255, alpha: 0.72)
            }
        )

        /// A message's words, and the done tone's glyph. Light #111214 ·
        /// Dark #FFFFFF. Contrast on the capsule: not measured.
        static let words: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0xFF/255, green: 0xFF/255, blue: 0xFF/255, alpha: 1)
                    : UIColor(red: 0x11/255, green: 0x12/255, blue: 0x14/255, alpha: 1)
            }
        )

        /// A message's small lines. Light #4A4A52 · Dark #B8B8C3: the
        /// support text token's values on the day this was written, kept
        /// here as numbers so they do not move when that token moves.
        /// Contrast on the capsule: not measured.
        static let secondaryWords: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0xB8/255, green: 0xB8/255, blue: 0xC3/255, alpha: 1)
                    : UIColor(red: 0x4A/255, green: 0x4A/255, blue: 0x52/255, alpha: 1)
            }
        )

        /// The capsule's inner edge, `edgeWidth` wide. Light black at 0.12 ·
        /// Dark white at 0.20; with Increase Contrast twice that: black at
        /// 0.24 · white at 0.40. Contrast: not measured.
        static let innerEdge: Color = Color(
            uiColor: UIColor { trait in
                let high = trait.accessibilityContrast == .high
                return trait.userInterfaceStyle == .dark
                    ? UIColor(red: 1, green: 1, blue: 1, alpha: high ? 0.40 : 0.20)
                    : UIColor(red: 0, green: 0, blue: 0, alpha: high ? 0.24 : 0.12)
            }
        )

        /// The capsule's outer edge, `edgeWidth` wide. Light black at 0.24 ·
        /// Dark white at 0.10; with Increase Contrast twice that: black at
        /// 0.48 · white at 0.20. Contrast: not measured.
        static let outerEdge: Color = Color(
            uiColor: UIColor { trait in
                let high = trait.accessibilityContrast == .high
                return trait.userInterfaceStyle == .dark
                    ? UIColor(red: 1, green: 1, blue: 1, alpha: high ? 0.20 : 0.10)
                    : UIColor(red: 0, green: 0, blue: 0, alpha: high ? 0.48 : 0.24)
            }
        )

        /// The width of each of the capsule's two edges, in points.
        static let edgeWidth: CGFloat = 0.5

        /// The quiet pill behind an action's label on the capsule. Light
        /// #111214 at 0.10 · Dark white at 0.16. Contrast: not measured.
        static let quietPill: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 1, green: 1, blue: 1, alpha: 0.16)
                    : UIColor(red: 0x11/255, green: 0x12/255, blue: 0x14/255, alpha: 0.10)
            }
        )

        /// The fill of a notice's action capsule. Light #16181A · Dark
        /// #FFFFFF. Contrast: not measured.
        static let solidPill: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0xFF/255, green: 0xFF/255, blue: 0xFF/255, alpha: 1)
                    : UIColor(red: 0x16/255, green: 0x18/255, blue: 0x1A/255, alpha: 1)
            }
        )

        /// The words on a notice's action capsule. Light #FFFFFF · Dark
        /// #16181A. Contrast: not measured.
        static let solidPillWords: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0x16/255, green: 0x18/255, blue: 0x1A/255, alpha: 1)
                    : UIColor(red: 0xFF/255, green: 0xFF/255, blue: 0xFF/255, alpha: 1)
            }
        )

        /// The capsule's fill, set from the app's appearance, not the
        /// content's scheme: in the light appearance #16181A at 0.94, in the
        /// dark appearance #F2F2F4 at 0.96; with Increase Contrast each at 1.
        static func surface(for appearance: ColorScheme, increasedContrast: Bool) -> Color {
            appearance == .dark
                ? Color(uiColor: UIColor(red: 0xF2/255, green: 0xF2/255, blue: 0xF4/255,
                                         alpha: increasedContrast ? 1 : 0.96))
                : Color(uiColor: UIColor(red: 0x16/255, green: 0x18/255, blue: 0x1A/255,
                                         alpha: increasedContrast ? 1 : 0.94))
        }

        /// The capsule's two black shadows, set from the app's appearance:
        /// light (y 4, blur 16, 0.18) and (y 1, blur 3, 0.14); dark (y 6,
        /// blur 22, 0.55) and (y 1, blur 3, 0.40). `blur` is the drawing's
        /// own blur figure; a view that draws it as a SwiftUI shadow radius
        /// halves it.
        static func shadows(for appearance: ColorScheme) -> [InkShadow] {
            appearance == .dark
                ? [InkShadow(y: 6, blur: 22, opacity: 0.55), InkShadow(y: 1, blur: 3, opacity: 0.40)]
                : [InkShadow(y: 4, blur: 16, opacity: 0.18), InkShadow(y: 1, blur: 3, opacity: 0.14)]
        }
    }

    /// One black shadow of the message capsule: its vertical offset and blur
    /// in points and its opacity. Read from `Ink.shadows(for:)`.
    // nonisolated: a plain value built inside the nonisolated colour group.
    nonisolated struct InkShadow: Equatable {
        let y: CGFloat
        let blur: CGFloat
        let opacity: Double
    }
}
