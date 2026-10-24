import SwiftUI
import CoreHaptics

// Centralized design tokens for Resecta.
// All magic numbers in the UI should reference these constants.

enum ResectaTokens {

    // MARK: - Spacing

    enum Spacing {
        /// 2pt — Hairline optical adjustments
        static let xxs: CGFloat = 2
        /// 4pt — Icon-to-label gap, compact sub-element spacing
        static let xs: CGFloat = 4
        /// 8pt — Intra-component padding, dense stack spacing
        static let sm: CGFloat = 8
        /// 16pt — Default padding, standard margins, screen-edge inset
        static let md: CGFloat = 16
        /// 24pt — Section spacing, group separation
        static let lg: CGFloat = 24
        /// 32pt — Major section breaks
        static let xl: CGFloat = 32
        /// 48pt — Page-level margins, large vertical separations
        static let xxl: CGFloat = 48

        /// 12pt — Toast vertical padding. Matches the research's explicit
        /// recommendation (Area 9). Not on the 8pt grid but accepted as a
        /// domain-specific exception per the research.
        static let toastVertical: CGFloat = 12

        /// 60pt — Clearance below glass toolbar for floating overlays
        /// (detection summary banner, background resume warning).
        static let toolbarClearance: CGFloat = 60
    }

    // MARK: - Corner Radii

    enum CornerRadius {
        /// 6pt — Small elements: badges, chips, small buttons
        static let small: CGFloat = 6
        /// 10pt — Medium: cards, panels, inline banners, layer result rows
        static let medium: CGFloat = 10
        /// 12pt — Toast rounded rectangle, content cards with icon+text.
        /// Matches research Area 9 explicit recommendation ("rounded rectangle with
        /// 12pt corner radius for icon + text messages"). Also covers the existing
        /// `cornerRadius: 12` values in LayerResultRow and verification banner.
        static let toast: CGFloat = 12
        /// 16pt — Content cards: pre-export confirmation sheet chrome
        /// (ConfirmationSheetChrome, lands in Phase 5 of the verification/
        /// export redesign). Below the research "Large" range (20–24pt) but
        /// retained because the sheet chrome reads as embedded content, not
        /// a floating overlay.
        static let card: CGFloat = 16
        /// 24pt — Sheets, modals, Liquid Glass floating overlays
        static let sheet: CGFloat = 24
        /// 25pt — the inset-grouped section of the results page, the
        /// system's own corner as measured on an iOS 26 simulator (a
        /// settings `Form` section at @3x).
        static let groupedSection: CGFloat = 25
        /// Capsule shape — pill buttons, single-line toasts. Use `Capsule()` shape.
    }

    // MARK: - Shadows

    enum Shadow {
        struct Elevation {
            let color: Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
        }

        /// Resting card, list cell. Dark-mode variant uses a faint white-tint
        /// shadow so elevated surfaces retain visible hierarchy against the
        /// dark background; light mode keeps the original 0.10 black tint.
        static let subtle = Elevation(
            color: Color(uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor.white.withAlphaComponent(0.04)
                    : UIColor.black.withAlphaComponent(0.10)
            }),
            radius: 6, x: 0, y: 2
        )
    }

    // MARK: - Opacity

    enum Opacity {
        /// Disabled control
        static let disabled: Double = 0.4
        /// Modal scrim behind sheets/overlays
        static let scrim: Double = 0.4

        // Severity tint overlays
        static let severityTint: Double = 0.10

        /// The tinted-tile wash — a brand or status hue behind a glyph or a
        /// chip's numeral (the Verification Details header's teal tile, the
        /// page chips): the `HomeChoiceCardContent` subtle-tile rule,
        /// tokenised. Light 0.10; dark 0.18, where the darker surface needs
        /// the stronger wash to read as a tile. Text on the wash stays on
        /// the text tier (`BrandTeal.text` measures 9.24 light / 7.62 dark
        /// on it).
        static let tileWashLight: Double = 0.10
        static let tileWashDark: Double = 0.18

        /// The Reduce Motion press: a primary-colour shade over a card in
        /// place of the scale and fade.
        static let pressOverlay: Double = 0.08
    }

    // MARK: - Borders

    enum Border {
        /// 0.5pt — Subtle border
        static let subtle: CGFloat = 0.5
    }

    // MARK: - Semantic Colors

    /// Semantic color tokens for detection, verification, and status UI.
    /// Wraps system colors into single-source-of-truth constants — change here
    /// to rebrand without hunting across views.
    // nonisolated: these are pure `Color` constants (Sendable design tokens), not
    // actor state. Under the SE-0466 MainActor-default flip the enum would become
    // MainActor-isolated, which breaks any nonisolated reader — e.g. a Swift Testing
    // `@Test(arguments:)` array, which the macro hoists into a nonisolated peer
    // (VerificationDisplayTests). Pin nonisolated so the tokens are usable from any
    // isolation (production views already read them on MainActor; unchanged there).
    nonisolated enum SemanticColor {
        // Confidence tiers — FILL tier (SearchResultRow confidence bar).
        // Small-text renders must NOT use these directly: system hues measure
        // as low as 1.51:1 as light-mode small text. Text
        // renders route through the status text tier below.
        /// ≥ 0.90 confidence
        static let confidenceHigh: Color = .green
        /// ≥ 0.70 confidence
        static let confidenceMedium: Color = .yellow
        /// < 0.70 confidence
        static let confidenceLow: Color = .orange

        // MARK: Status text tier
        // WCAG-AA-validated shades for SMALL status TEXT only. Same hue
        // families as the glyph/fill tier (green/amber/yellow/red/blue),
        // darkened (light) or lightened (dark) until ≥4.5:1 on the surfaces
        // they render over. Glyphs, badges, region strokes, and toast tints
        // stay on the system-color tier — do not route them here.

        /// PASS-family text. Light #1B7A33 · Dark #30D158 (systemGreen dark).
        /// Measured: 5.41/4.85 light (white/grouped) · 8.42/6.89 dark.
        static let passText: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0x30/255, green: 0xD1/255, blue: 0x58/255, alpha: 1)
                    : UIColor(red: 0x1B/255, green: 0x7A/255, blue: 0x33/255, alpha: 1)
            }
        )

        /// WARN-family text. Light #9A5B00 · Dark #FF9F0A (systemOrange dark).
        /// Measured: 5.43/4.86 light · 8.28/6.78 dark.
        static let warnText: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0xFF/255, green: 0x9F/255, blue: 0x0A/255, alpha: 1)
                    : UIColor(red: 0x9A/255, green: 0x5B/255, blue: 0x00/255, alpha: 1)
            }
        )

        /// Medium-confidence text (yellow family). Light #7A6100 · Dark
        /// #FFD60A (systemYellow dark). Measured: 5.94/5.32 light ·
        /// 12.05/9.87 dark.
        static let confidenceMediumText: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0xFF/255, green: 0xD6/255, blue: 0x0A/255, alpha: 1)
                    : UIColor(red: 0x7A/255, green: 0x61/255, blue: 0x00/255, alpha: 1)
            }
        )

        /// FAIL-family text. Light #C2262E · Dark #FF7A72 (system dark red
        /// is 4.09 on #2C2C2E — below 4.5, hence the custom dark shade).
        /// Measured: 5.82/5.21 light · 6.71/5.49 dark.
        static let failText: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0xFF/255, green: 0x7A/255, blue: 0x72/255, alpha: 1)
                    : UIColor(red: 0xC2/255, green: 0x26/255, blue: 0x2E/255, alpha: 1)
            }
        )

        /// INFO-family text. Light #1D5EBF · Dark #6CB4EE (system dark blue
        /// is 3.82 on #2C2C2E). Measured: 6.17/5.53 light · 7.62/6.24 dark.
        static let infoText: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0x6C/255, green: 0xB4/255, blue: 0xEE/255, alpha: 1)
                    : UIColor(red: 0x1D/255, green: 0x5E/255, blue: 0xBF/255, alpha: 1)
            }
        )

        /// ATTENTION-family text (pink family — shares
        /// `VerificationStatus.color`'s `.pink` glyph hue; distinct from
        /// warn orange / fail red). Light #D40028 · Dark #FF6E8B.
        /// Measured: 5.48/4.91 light (white/grouped) · 7.86/6.36/5.21
        /// dark (black/#1C1C1E/#2C2C2E).
        static let attentionText: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0xFF/255, green: 0x6E/255, blue: 0x8B/255, alpha: 1)
                    : UIColor(red: 0xD4/255, green: 0x00/255, blue: 0x28/255, alpha: 1)
            }
        )

        /// SUPPORT-family text (neutral grey). Darker support tier
        /// for the small explanatory text on Home and the verification
        /// screens (card bodies, subtitles, run facts, trust labels, the
        /// version and timing footers) — replaces system `.secondary`
        /// (≈4.6:1) and `.tertiary` (≈2.3:1) there, which measure below
        /// the 7:1 target as light-mode small text. Light #4A4A52 ·
        /// Dark #B8B8C3. Measured: 8.78/7.87 light (white/grouped) ·
        /// 10.68/8.66/7.09 dark (black/#1C1C1E/#2C2C2E).
        static let supportText: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0xB8/255, green: 0xB8/255, blue: 0xC3/255, alpha: 1)
                    : UIColor(red: 0x4A/255, green: 0x4A/255, blue: 0x52/255, alpha: 1)
            }
        )

        // Detection kind badge colors (canvas badges, triage rows, popover)
        static let badgePII: Color = Color(.systemOrange)

        // Accent colors
        /// Region count indicator in page navigation bar
        static let regionCountAccent: Color = .orange
        /// Searchable mode icon/legend tint in verification results
        static let searchableMode: Color = .blue
        /// Warning banner background tint
        static let warningTint: Color = .orange

        // Result-row source badges (search results list)
        /// Purple capsule on rows whose rationale signals contain
        /// `.userAlwaysFlag` — distinguishes user-defined always-flag
        /// term hits from detector matches and source badges.
        static let customTermBadge: Color = Color(uiColor: .systemPurple)

        /// Indigo capsule on rows produced
        /// by a regex-mode search whose rationale signals contain
        /// `.regexPattern(...)`. Distinct hue from OCR teal
        /// — the original proposal of `.systemTeal.opacity(0.85)` was
        /// flagged for visual confusion with OCR teal at small sizes /
        /// display calibration variance; the indigo fallback (already
        /// proposed for `savedRegexLabel`) is unused by any existing
        /// capsule and reads distinctly at AX5 + dark mode.
        static let regexBadge: Color = Color(uiColor: .systemIndigo)
    }

    // MARK: - Snap Guides

    enum Snap {
        /// Distance (in screen points; × the overlay's finger scale) within
        /// which an edge aligns to a guide.
        static let proximityThreshold: CGFloat = 5
        /// Width of rendered guide lines.
        static let guideLineWidth: CGFloat = 1.0
        /// Guide line color — orange for contrast (matches WARN color rationale).
        static let guideColor: UIColor = .systemOrange
    }

    // MARK: - Touch Targets

    enum TouchTarget {
        /// 22pt — Apple Pencil hit area
        static let pencil: CGFloat = 22
        /// 46pt — Apple HIG minimum EFFECTIVE (as-hit-tested) touch
        /// target floor. The default-size floor for
        /// interactive controls whose visual glyph/label is smaller
        /// than this — enlarge the tappable frame/contentShape around
        /// the content, never the glyph or label itself.
        ///
        /// 46 = 44 ÷ 0.96 — the medium-detent inset sheet
        /// renders its content at ~0.96 scale on iOS 26 (measured
        /// 2026-08-22 on the iPhone 17 Pro sim: a 44-pt frame lands at
        /// 42.2 pt effective), so a 46-pt layout frame yields ≥ 44pt
        /// effective inside the sheet and 46pt outside it (page bar,
        /// canvas) — harmless. The floor is defined as the EFFECTIVE size,
        /// not the layout frame, hence 46 rather than 44 here.
        ///
        /// This enum previously included a
        /// `TouchTarget.finger: CGFloat = 44` member that was removed as
        /// dead code (never read). This is a deliberate re-introduction
        /// of the same idea under a new name for a new, now-referenced
        /// purpose.
        static let minimum: CGFloat = 46
    }

    // MARK: - Verification results

    /// The verification results page: the count ring, the action capsules,
    /// the grouped sections and their rows. Measured against the design of
    /// record at 390 pt.
    nonisolated enum Results {
        /// The count ring: 80 pt across, a 4-pt round-capped arc.
        static let ringSize: CGFloat = 80
        static let ringStroke: CGFloat = 4
        /// The ring's figure: 22 pt below ten checks, 20 pt from ten.
        static let ringFigureSmallCount: CGFloat = 22
        static let ringFigureLargeCount: CGFloat = 20
        /// The word under the figure and the SKIPPED glyph.
        static let ringWord: CGFloat = 12
        static let ringSkippedGlyph: CGFloat = 30
        /// The ring's track: tertiary fill, 0.12 light / 0.32 dark.
        static let trackOpacityLight: Double = 0.12
        static let trackOpacityDark: Double = 0.32
        /// A report that passed nothing draws the whole track in the
        /// verdict's text colour, never a solid ring.
        static let zeroTrackOpacityLight: Double = 0.24
        static let zeroTrackOpacityDark: Double = 0.40
        /// The arc's draw-in: once, after the entry flash.
        static let arcDrawIn: Animation = .easeOut(duration: 0.6)
        static let arcDrawInDelay: TimeInterval = 1.2

        /// Gaps of the masthead: ring → title 12, title → sentence 4,
        /// sentence → the first capsule 24. The sentence's column cap.
        static let ringToTitle: CGFloat = 12
        static let titleToSentence: CGFloat = 4
        static let sentenceMaxWidth: CGFloat = 326

        /// The action capsules: 50 pt tall, 12 apart; the outlined stroke.
        static let capsuleHeight: CGFloat = 50
        static let capsuleGap: CGFloat = 12
        static let capsuleStroke: CGFloat = 1.5
        /// The disabled reason under its capsule; the gap to the next block.
        static let reasonGap: CGFloat = 8
        static let blockGap: CGFloat = 24

        /// A section header hugs its section.
        static let headerGap: CGFloat = 6
        /// Rows: at least 52 pt; the leading column 28 wide, the titles at 56.
        static let rowMinHeight: CGFloat = 52
        static let rowVerticalPadding: CGFloat = 11
        /// The chevron's column: 12 wide, 8 after the text, 16 to the edge.
        static let chevronColumn: CGFloat = 12
        static let leadColumn: CGFloat = 28
        static let leadMark: CGFloat = 22
        static let titleInset: CGFloat = 56
        static let actionTile: CGFloat = 28
        static let actionTileRadius: CGFloat = 7
        /// The opened row's wash.
        static let rowWashLight: Double = 0.035
        static let rowWashDark: Double = 0.06
        /// The opened block: the lead group, 12, the reference lines at 8.
        static let leadToReference: CGFloat = 12
        /// Page chips: 26 tall, padded 10; at most five on a collapsed row.
        static let chipHeight: CGFloat = 26
        static let chipPadding: CGFloat = 10
        static let chipPressedOpacity: Double = 0.5
        static let chipCap = 5
        /// The completion line to the legal text; SKIPPED's undo note to it.
        static let completionToLegal: CGFloat = 18
        static let undoToLegalSkipped: CGFloat = 32

        /// The light WARN arc: a ring-only orange (#C26A00), the text tier
        /// reading bronze at 4 pt; dark keeps `warnText`.
        static let warnRing: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0xFF/255, green: 0x9F/255, blue: 0x0A/255, alpha: 1)
                    : UIColor(red: 0xC2/255, green: 0x6A/255, blue: 0x00/255, alpha: 1)
            }
        )
    }

    // MARK: - Branded Surface

    // MARK: - Home entries

    /// The home screen's entries: the three cards, the mark and the
    /// stack's spacing. The tile sizes are fixed points (the glyphs
    /// do not scale with Dynamic Type); the accessibility sizes restack
    /// every entry with the smaller tile above its text.
    enum HomeEntry {
        /// Between entries.
        static let gap: CGFloat = 12
        /// The slot every tile sits in, so the text starts on one edge.
        static let slot: CGFloat = 56
        /// A card's tile, its radius and glyph.
        static let tile: CGFloat = 56
        static let tileRadius: CGFloat = 14
        static let tileGlyph: CGFloat = 28
        /// The tile at accessibility sizes.
        static let tileAX: CGFloat = 44
        static let tileRadiusAX: CGFloat = 11
        static let tileGlyphAX: CGFloat = 22
        /// The mark's tile side in the masthead, the gate and the overlay:
        /// about the width of the 'Resecta' title, so the two read as one.
        static let markTile: CGFloat = 96
        /// The tagline's width cap.
        static let taglineMaxWidth: CGFloat = 320
        /// The stack's vertical padding at every size.
        static let verticalPad: CGFloat = 24
        /// The press.
        static let pressScale: CGFloat = 0.985
        static let pressOpacity: Double = 0.9
    }

    enum BrandedSurface {
        /// Content panel max width — compact size class and default
        static let panelMaxWidthCompact: CGFloat = 380

        /// Content panel max width — regular size class (iPad)
        static let panelMaxWidthRegular: CGFloat = 420

    }

    // MARK: - Brand Teal

    /// Brand accent tokens — the redaction-teal pair that matches the marketing
    /// site. `tint` must stay component-equal to the AccentColor colorset in
    /// Resources/Assets.xcassets (AccentColorLockstepTests pins this).
    /// Keep the hex values centralized here so future contributors don't
    /// scatter them across views; do not retune without design review.
    // nonisolated: same SE-0466 rationale as SemanticColor above — these are
    // Sendable design-token constants read from nonisolated test contexts.
    nonisolated enum BrandTeal {
        /// Global tint. Light #0B646F · Dark #128697 (iOS-tuned inside the
        /// site family). Measured: white-on-fill 6.85 light / 4.30 dark;
        /// glyph vs washes ≥3.24 worst (contrast runs, 2026-07-08).
        static let tint: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0x12/255, green: 0x86/255, blue: 0x97/255, alpha: 1)
                    : UIColor(red: 0x0B/255, green: 0x64/255, blue: 0x6F/255, alpha: 1)
            }
        )

        /// Filled-capsule tier — the white-label action capsules (the
        /// sheet footer's Select All, the parked strip's per-item Apply).
        /// Light #0B646F (= the tint; white-on-fill 6.85) · Dark #117F8F
        /// (white-on-fill 4.71 — the dark tint's 4.30 sat under AA for a
        /// headline label; contrast runs, 2026-09-24). The global tint
        /// (glyphs, the current-match ring) is untouched.
        static let fill: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0x11/255, green: 0x7F/255, blue: 0x8F/255, alpha: 1)
                    : UIColor(red: 0x0B/255, green: 0x64/255, blue: 0x6F/255, alpha: 1)
            }
        )

        /// Text tier — colored small text and small glyphs (affordances, chip
        /// counts, trust checks, disclosure icons). Light #0A5D66 · Dark
        /// #7BD7E2. Measured: 7.58/6.79/6.18 light (white/grouped/wash),
        /// 12.66–8.24 dark — all AA for small text (CP1 contrast runs).
        static let text: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0x7B/255, green: 0xD7/255, blue: 0xE2/255, alpha: 1)
                    : UIColor(red: 0x0A/255, green: 0x5D/255, blue: 0x66/255, alpha: 1)
            }
        )

        /// The glyph on a washed tile (the subtle entries' tiles). Light =
        /// the tint #0B646F · Dark #3FAEBD (5.3 / 5.0:1 on the wash).
        static let tileGlyph: Color = Color(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0x3F/255, green: 0xAE/255, blue: 0xBD/255, alpha: 1)
                    : UIColor(red: 0x0B/255, green: 0x64/255, blue: 0x6F/255, alpha: 1)
            }
        )
    }

    // MARK: - The mark

    /// The app icon, drawn in code: its paper field, two ink bars, one teal
    /// bar and twelve grey text runs, in the icon's own colours (measured from
    /// the 1024 px icons, light and dark). Decorative colours, no contrast
    /// floor; under Increase Contrast the ink goes to pure black or white and
    /// the tile's edge darkens.
    nonisolated enum BrandMark {
        /// The tile's field. Light #FBFAF6 · Dark #000000.
        static let field: Color = dynamic(light: 0xFBFAF6, dark: 0x000000)
        /// Bars one and two. Light #0E0E14 · Dark #F2F1EC; Increase
        /// Contrast #000000 · #FFFFFF.
        static let ink: Color = dynamic(light: 0x0E0E14, dark: 0xF2F1EC, lightHigh: 0x000000, darkHigh: 0xFFFFFF)
        /// The third bar. Light #128697 · Dark #1799AC.
        static let teal: Color = dynamic(light: 0x128697, dark: 0x1799AC)
        /// The text runs. Light #8B887F · Dark #A5A39B.
        static let runs: Color = dynamic(light: 0x8B887F, dark: 0xA5A39B)
        /// The tile's 0.5 pt edge, top to bottom: a black hairline in light
        /// (0.07; 0.20 at Increase Contrast); in dark a white rim, brightest at
        /// the top, that keeps the black tile's outline on a black screen
        /// (0.32 · 0.14 · 0.20; 0.55 · 0.40 · 0.45).
        static let edge: [Color] = [
            edgeColor(light: 0.07, dark: 0.32, lightHigh: 0.20, darkHigh: 0.55),
            edgeColor(light: 0.07, dark: 0.14, lightHigh: 0.20, darkHigh: 0.40),
            edgeColor(light: 0.07, dark: 0.20, lightHigh: 0.20, darkHigh: 0.45),
        ]
        /// The tile's shadow: the resting card's black 0.10 in light; none in
        /// dark, where a glow beneath a top-lit tile would read as lit from
        /// below.
        static let shadow: Color = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? .clear : UIColor.black.withAlphaComponent(0.10)
        })

        private static func dynamic(light: UInt32, dark: UInt32, lightHigh: UInt32? = nil, darkHigh: UInt32? = nil) -> Color {
            Color(uiColor: UIColor { trait in
                let high = trait.accessibilityContrast == .high
                let hex = trait.userInterfaceStyle == .dark
                    ? (high ? darkHigh ?? dark : dark)
                    : (high ? lightHigh ?? light : light)
                return UIColor(
                    red: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255,
                    alpha: 1
                )
            })
        }

        private static func edgeColor(light: CGFloat, dark: CGFloat, lightHigh: CGFloat, darkHigh: CGFloat) -> Color {
            Color(uiColor: UIColor { trait in
                let high = trait.accessibilityContrast == .high
                return trait.userInterfaceStyle == .dark
                    ? UIColor.white.withAlphaComponent(high ? darkHigh : dark)
                    : UIColor.black.withAlphaComponent(high ? lightHigh : light)
            })
        }
    }

    // MARK: - Animation Presets

    /// Named animation presets. Replaces ad-hoc per-view values.
    enum Anim {
        // MARK: State Changes
        /// Button/toolbar state changes, toggles
        static let stateChange: Animation = .snappy(duration: 0.25)
        /// Phase transitions (draw → review → export)
        static let modeTransition: Animation = .spring(response: 0.35, dampingFraction: 0.85)

        // MARK: Overlays
        /// Overlay/sheet dismissal (faster than appear)
        static let overlayDismiss: Animation = .smooth(duration: 0.25)

        // MARK: Toasts
        /// Toast entrance (slide + fade)
        static let toastIn: Animation = .spring(response: 0.35, dampingFraction: 0.78)
        /// Toast exit (no bounce on dismissal)
        static let toastOut: Animation = .easeIn(duration: 0.2)

        /// Handle-appearance duration for the resize-handle
        /// CADisplayLink path. `RedactionOverlayView` interpolates a custom
        /// `handleScale` CGFloat that SwiftUI's `Animation` value cannot
        /// drive — the duration is read by hand from this token.
        static let selectionInDuration: TimeInterval = 0.2

        /// Handle-disappearance duration, same CADisplayLink path.
        static let selectionOutDuration: TimeInterval = 0.15

        // MARK: Attention
        /// One-shot grabber pulse on first compact-detent drop.
        /// Single up-and-back oscillation
        /// (0.45s + autoreverse) — long enough to register, short enough
        /// not to feel slow. Reduce Motion suppresses entirely at the
        /// call site (the predicate gate skips the pulse rather than
        /// relying on `Anim.resolved` since the animation is meant as
        /// a one-shot affordance hint, not a state-change cue).
        static let attentionPulse: Animation = .easeInOut(duration: 0.45)
            .repeatCount(1, autoreverses: true)

        // MARK: Verification
        /// Status color change (gray → green/red)
        static let colorTransition: Animation = .easeInOut(duration: 0.3)

        // MARK: Reduced Motion
        /// Returns the reduced-motion equivalent of an animation if the user prefers it.
        /// Call site reads accessibilityReduceMotion from @Environment and passes it in.
        static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation? {
            if reduceMotion {
                return .easeInOut(duration: 0.2)
            }
            return animation
        }

        // MARK: Reduced Motion — partial revival
        //
        // This transition helper was removed as dead code (never read)
        // in the same sweep that removed the `Haptics` enum above. It
        // has since gained its first real call sites: the eleven
        // `.move(edge:)` transition sites under
        // `Sources/ResectaApp/Views`. This is a MINIMAL, deliberate
        // partial revival — only this one function is restored,
        // verbatim from `git show 09dd889a81af6091287d8e3819d05e608a2184ca`
        // — the other removed members (Typography, the
        // never-read TouchTarget/CornerRadius/Shadow/Opacity/Border/Anim
        // members) are not brought back; they stay confirmed-dead.
        /// Transition for reduced-motion contexts. Replaces spatial transitions
        /// (slide, scale) with opacity-only crossfade.
        static func resolvedTransition(
            standard: AnyTransition,
            reduceMotion: Bool
        ) -> AnyTransition {
            reduceMotion ? .opacity : standard
        }
    }

    // MARK: - Haptics — partial revival
    //
    // This enum previously held the full `Haptics` implementation — 13
    // string-constant "intended haptic" documentation entries plus this
    // `playExportConfirmation()` CoreHaptics implementation — removed as
    // confirmed-dead: zero readers/callers anywhere, export shipped
    // with no haptic at all. `playExportConfirmation()` now has its
    // first real call site (the share-risk confirm sheet's
    // slide-to-confirm completion). This is a MINIMAL, deliberate
    // partial revival — only the empty `Haptics`
    // namespace and this one function are restored, verbatim from
    // `git show 09dd889a81af6091287d8e3819d05e608a2184ca` — the other 12
    // now-unused string constants are NOT brought
    // back and stay confirmed-dead.
    enum Haptics {}
}

extension ResectaTokens.Haptics {
    /// Two-part haptic for the irreversible export confirmation.
    /// Part 1 (t=0.0): Sharp transient — "this is serious"
    /// Part 2 (t=0.15s): Heavy transient — "committed"
    static func playExportConfirmation() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }

        do {
            let engine = try CHHapticEngine()
            try engine.start()

            let sharpTransient = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8),
                ],
                relativeTime: 0
            )

            let heavyTransient = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                ],
                relativeTime: 0.15
            )

            let pattern = try CHHapticPattern(events: [sharpTransient, heavyTransient],
                                               parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch { // LegalPhrases:safe (Swift keyword)
            // Haptic failure is non-critical — silently degrade
        }
    }
}
