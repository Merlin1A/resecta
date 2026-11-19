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
    }
}
