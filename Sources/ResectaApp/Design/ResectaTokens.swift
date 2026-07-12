import SwiftUI
import CoreHaptics

// §A1: Centralized design tokens for Resecta.
// All magic numbers in the UI should reference these constants.

enum ResectaTokens {

    // MARK: - Typography

    enum Typography {
        static let sectionHeader: Font = .headline              // 17pt Semibold
        static let layerName: Font = .headline                  // 17pt Semibold
        static let bodyText: Font = .body                       // 17pt Regular
        static let caption: Font = .caption                     // 12pt Regular
        static let statusBadge: Font = .caption.weight(.bold)   // 12pt Bold
        static let monoDigit: Font = .body.monospacedDigit()    // 17pt tabular figures
    }

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
        /// a floating overlay. Distinct from `.large` for semantic clarity.
        static let card: CGFloat = 16
        /// 20pt — Large floating elements: PipelineProgressCard, popovers.
        /// Matches the lower bound of the research "Large" range (20–24pt)
        /// and the PipelineProgressCard floating overlay value.
        static let large: CGFloat = 20
        /// 24pt — Sheets, modals, Liquid Glass floating overlays
        static let sheet: CGFloat = 24
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
        /// 02-dark-mode-design.md §7.1.
        static let subtle = Elevation(
            color: Color(uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor.white.withAlphaComponent(0.04)
                    : UIColor.black.withAlphaComponent(0.10)
            }),
            radius: 6, x: 0, y: 2
        )
        /// Floating bar, toast, FAB. Adaptive per 02-dark-mode-design.md §7.1.
        static let medium = Elevation(
            color: Color(uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor.white.withAlphaComponent(0.07)
                    : UIColor.black.withAlphaComponent(0.17)
            }),
            radius: 12, x: 0, y: 4
        )
        /// Sheet, modal, picker. Adaptive per 02-dark-mode-design.md §7.1.
        static let heavy = Elevation(
            color: Color(uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor.white.withAlphaComponent(0.12)
                    : UIColor.black.withAlphaComponent(0.25)
            }),
            radius: 20, x: 0, y: 8
        )
    }

    // MARK: - Opacity

    enum Opacity {
        // Label hierarchy — prefer SwiftUI .primary/.secondary/.tertiary
        static let labelPrimary: Double = 1.0
        static let labelSecondary: Double = 0.6
        static let labelTertiary: Double = 0.3
        static let labelQuaternary: Double = 0.18

        // Interaction states
        /// Button pressed/highlighted foreground dim
        static let pressed: Double = 0.2
        /// Disabled control
        static let disabled: Double = 0.4
        /// Modal scrim behind sheets/overlays
        static let scrim: Double = 0.4

        // Region fill (see §2.5 for reduce-transparency variant)
        static let regionFill: Double = 0.30
        static let regionFillReducedTransparency: Double = 0.60
        static let rubberBandFill: Double = 0.15

        // Severity tint overlays (see §A6 Toast Severity)
        static let severityTint: Double = 0.10
    }

    // MARK: - Borders

    enum Border {
        /// 0.33pt — Hairline separator (1 pixel on 3× Retina). SwiftUI Divider() default.
        static let hairline: CGFloat = 1.0 / 3.0
        /// 0.5pt — Subtle border
        static let subtle: CGFloat = 0.5
        /// 1pt — Standard border, snap guide line
        static let standard: CGFloat = 1.0
        /// 2pt — Region border (unselected), emphasized selection
        static let regionUnselected: CGFloat = 2.0
        /// 2.5pt — Region border (selected). Preserves existing spec §2.5 value;
        /// research Area 4 suggests 2pt but 2.5pt provides better visual distinction
        /// from the 2.0pt unselected border. Revisit if visual testing indicates otherwise.
        static let regionSelected: CGFloat = 2.5
        /// 3pt — Heavy accent stroke, iPad sidebar selected-page highlight
        static let heavy: CGFloat = 3.0
    }

    // MARK: - Semantic Colors

    /// Semantic color tokens for detection, verification, and status UI.
    /// Wraps system colors into single-source-of-truth constants — change here
    /// to rebrand without hunting across views.
    // nonisolated: these are pure `Color` constants (Sendable design tokens), not
    // actor state. Under the s04 SE-0466 MainActor-default flip the enum would become
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

        // Detection kind badge colors (canvas badges, triage rows, popover)
        static let badgePII: Color = Color(.systemOrange)
        static let badgeFace: Color = Color(.systemPurple)

        // Accent colors
        /// Region count indicator in page navigation bar
        static let regionCountAccent: Color = .orange
        /// Searchable mode icon/legend tint in verification results
        static let searchableMode: Color = .blue
        /// Warning banner background tint
        static let warningTint: Color = .orange

        // Result-row source badges (search results list)
        /// WU-06: purple capsule on rows whose rationale signals contain
        /// `.userAlwaysFlag` — distinguishes user-defined always-flag
        /// term hits from detector matches and source badges.
        static let customTermBadge: Color = Color(uiColor: .systemPurple)

        /// WU-63 / TOKEN_ADDITIONS.md: indigo capsule on rows produced
        /// by a regex-mode search whose rationale signals contain
        /// `.regexPattern(...)`. Distinct hue from OCR teal per [RR-19]
        /// — the original proposal of `.systemTeal.opacity(0.85)` was
        /// flagged for visual confusion with OCR teal at small sizes /
        /// display calibration variance; the indigo fallback (already
        /// proposed for `savedRegexLabel`) is unused by any existing
        /// capsule and reads distinctly at AX5 + dark mode.
        static let regexBadge: Color = Color(uiColor: .systemIndigo)
    }

    // MARK: - Snap Guides (§A7)

    enum Snap {
        /// Distance (in overlay points) within which an edge snaps to a guide.
        static let proximityThreshold: CGFloat = 10
        /// Width of rendered guide lines.
        static let guideLineWidth: CGFloat = 1.0
        /// Guide line color — orange for contrast (matches WARN color rationale).
        static let guideColor: UIColor = .systemOrange
        /// Page margin inset for margin guide lines.
        static let pageMarginInset: CGFloat = 16
    }

    // MARK: - Touch Targets

    enum TouchTarget {
        /// 44pt — Minimum touch target (Apple HIG), finger input
        static let finger: CGFloat = 44
        /// 24pt — Trackpad/mouse pointer hit area
        static let pointer: CGFloat = 24
        /// 22pt — Apple Pencil hit area
        static let pencil: CGFloat = 22
        /// 10pt — Visible resize handle diameter
        static let resizeHandleVisible: CGFloat = 10
    }

    // MARK: - Branded Surface (Design Spec §5)

    enum BrandedSurface {
        /// Content panel max width — compact size class and default
        static let panelMaxWidthCompact: CGFloat = 380

        /// Content panel max width — regular size class (iPad)
        static let panelMaxWidthRegular: CGFloat = 420

    }

    // MARK: - Brand Teal (color initiative, CD-14/CD-15/CD-19)

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
    }

    // MARK: - Animation Presets (§A2)

    /// Named animation presets. Replaces ad-hoc per-view values (UI_UX_SPEC_AMENDMENT §A2).
    enum Anim {
        // MARK: State Changes
        /// Button/toolbar state changes, toggles
        static let stateChange: Animation = .snappy(duration: 0.25)
        /// Phase transitions (draw → review → export)
        static let modeTransition: Animation = .spring(response: 0.35, dampingFraction: 0.85)

        // MARK: Overlays
        /// Progress overlay, blur/dim appearance
        static let overlayAppear: Animation = .smooth(duration: 0.3)
        /// Overlay/sheet dismissal (faster than appear)
        static let overlayDismiss: Animation = .smooth(duration: 0.25)
        /// Background blur/dim behind overlays
        static let contentDim: Animation = .easeInOut(duration: 0.3)

        // MARK: Toasts
        /// Toast entrance (slide + fade)
        static let toastIn: Animation = .spring(response: 0.35, dampingFraction: 0.78)
        /// Toast exit (no bounce on dismissal)
        static let toastOut: Animation = .easeIn(duration: 0.2)

        // MARK: Region Interaction
        /// Region snap-to-grid/position after drawing
        static let regionSettle: Animation = .spring(response: 0.3, dampingFraction: 0.7)
        /// Region delete: scale to 0.8 + fade to 0
        static let regionDelete: Animation = .spring(response: 0.25, dampingFraction: 0.9)
        /// Handle appearance, selection highlight
        static let selectionIn: Animation = .snappy(duration: 0.2)
        /// Handle disappearance, deselection
        static let selectionOut: Animation = .easeOut(duration: 0.15)

        /// WU-43 M-D.5: TimeInterval companion to `selectionIn` for the
        /// resize-handle CADisplayLink path. `RedactionOverlayView`
        /// interpolates a custom `handleScale` CGFloat that SwiftUI's
        /// `Animation` value cannot drive — the duration is read by hand
        /// from this token. Kept in lock-step with the SwiftUI variant.
        static let selectionInDuration: TimeInterval = 0.2

        /// WU-43 M-D.5: TimeInterval companion to `selectionOut`.
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
        /// Companion to .contentTransition(.numericText())
        static let numericCount: Animation = .snappy(duration: 0.3)
        /// Per-item stagger in verification results list.
        /// 0.035s interval compresses 8-layer cascade to 0.28s spread — snappy
        /// without losing perceptibility.
        static func stagger(index: Int) -> Animation {
            .snappy(duration: 0.35).delay(min(Double(index) * 0.035, 0.35))
        }
        /// Status color change (gray → green/red)
        static let colorTransition: Animation = .easeInOut(duration: 0.3)

        // MARK: Progress (§A4)
        /// Progress bar fill to 100%
        static let progressComplete: Animation = .easeInOut(duration: 0.3)

        // MARK: Reduced Motion (§A2.2)
        /// Returns the reduced-motion equivalent of an animation if the user prefers it.
        /// Call site reads accessibilityReduceMotion from @Environment and passes it in.
        static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation? {
            if reduceMotion {
                return .easeInOut(duration: 0.2)
            }
            return animation
        }

        /// Transition for reduced-motion contexts. Replaces spatial transitions
        /// (slide, scale) with opacity-only crossfade.
        static func resolvedTransition(
            standard: AnyTransition,
            reduceMotion: Bool
        ) -> AnyTransition {
            reduceMotion ? .opacity : standard
        }
    }

    // MARK: - Haptic Choreography (§A3)

    /// Haptic feedback map (UI_UX_SPEC_AMENDMENT §A3).
    /// Use SwiftUI `.sensoryFeedback(_:trigger:)` as the primary API.
    /// UIKit `UIFeedbackGenerator` subclasses are the fallback for UIView code paths
    /// (RedactionOverlayView).
    ///
    /// Always call `.prepare()` before time-critical haptic events to reduce
    /// Taptic Engine latency.
    ///
    /// The string constants below name the intended haptic for each interaction.
    /// Each call site uses the actual `.sensoryFeedback` modifier or `UIFeedbackGenerator`
    /// subclass directly (see §A3.4 wiring table and §A3.5 SwiftUI examples).
    enum Haptics {
        // MARK: Region Interaction (UIKit — overlay view)
        /// Physical "stamp placed" metaphor. Fire on touchesEnded when region is committed.
        /// UIKit: UIImpactFeedbackGenerator(.medium).impactOccurred()
        static let regionCommitted = "impact.medium"

        /// Apple standard for selection state changes. Fire on region tap-to-select.
        /// UIKit: UISelectionFeedbackGenerator().selectionChanged()
        static let regionSelected = "selection"

        /// Crisp, definitive removal. Fire on region delete (after undo registration).
        /// UIKit: UIImpactFeedbackGenerator(.rigid).impactOccurred(intensity: 0.8)
        static let regionDeleted = "impact.rigid.0.8"

        /// Already implemented (§2.2). Subtle "nope" for sub-threshold regions.
        /// UIKit: UIImpactFeedbackGenerator(.light).impactOccurred(intensity: 0.3)
        static let subThresholdRejection = "impact.light.0.3"

        /// Fire when a region edge snaps to a guide (see §A7).
        /// SwiftUI: .sensoryFeedback(.alignment, trigger: snapPosition)
        static let snapAlignment = "alignment"

        // MARK: State Transitions (SwiftUI — view modifiers)
        /// Gentle, ambient transition. Fire on phase change (draw → review → export).
        /// SwiftUI: .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger:)
        static let modeSwitch = "impact.soft.0.5"

        /// Subtle, frequent action. Fire on undo/redo.
        /// SwiftUI: .sensoryFeedback(.impact(weight: .light), trigger:)
        static let undoRedo = "impact.light"

        // MARK: Pipeline Milestones (SwiftUI)
        /// Positive milestone. Fire when auto-detection completes.
        /// SwiftUI: .sensoryFeedback(.success, trigger:)
        static let detectionComplete = "success"

        /// Major milestone completion. Fire when redaction pipeline finishes
        /// (before verification begins).
        /// SwiftUI: .sensoryFeedback(.success, trigger:)
        static let pipelineComplete = "success"

        // MARK: Verification Results (SwiftUI)
        /// Satisfying confirmation. Fire when overall status is PASS.
        /// SwiftUI: .sensoryFeedback(.success, trigger:)
        static let verificationPass = "success"

        /// Medium attention-getting pulse. Fire when overall status is WARN.
        /// SwiftUI: .sensoryFeedback(.warning, trigger:)
        static let verificationWarn = "warning"

        /// Distinct triple-buzz alert. Fire when overall status is FAIL.
        /// SwiftUI: .sensoryFeedback(.error, trigger:)
        static let verificationFail = "error"
    }
}

// MARK: - Export Confirmation AHAP (§A3.2)

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
        } catch {
            // Haptic failure is non-critical — silently degrade
        }
    }
}
