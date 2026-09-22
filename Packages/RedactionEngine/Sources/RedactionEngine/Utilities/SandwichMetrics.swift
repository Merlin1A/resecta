import CoreGraphics
import CoreText
import CryptoKit
import Foundation

/// The metrics the searchable text-layer writer and its verifier share.
///
/// The reconstructor draws the rebuilt layer to these numbers and the
/// sandwich verification layers read the output back against the same
/// numbers, so both sides must agree on them by construction. One home for
/// the shared set keeps `Pipeline/` and `Verification/` from reaching into
/// each other for a constant: the writer-local values (`baseFontSize`,
/// `cellWidth`) stay with the reconstructor.
public enum SandwichMetrics {

    // MARK: - Courier geometry

    /// Courier monospace advance-per-point constant. CoreText's 16-bit
    /// fixed-point representation of Adobe Font Metrics' 600-units-per-em
    /// Courier advance (600/1000 = 0.6). Probed against
    /// `CTFontGetAdvancesForGlyphs` for sizes {1, 6, 12, 24, 100}pt — the
    /// advance is exactly `0.60009765625 × fontSize` for every probed size.
    public static let courierAdvancePerPoint: CGFloat = 0.60009765625

    /// Tolerance for the Layer 6 advance crosscheck at the 12pt REFERENCE
    /// size (M1 tightening). The reconstructor derives line pitches from
    /// source metrics, so the operative tolerance scales linearly with the
    /// glyph's own point size via `advanceWidthTolerancePerPoint`; this
    /// constant remains the 12pt anchor (and the value probe/test code
    /// built against the 12pt-era geometry still reads).
    public static let advanceWidthTolerance: CGFloat = 0.25

    /// Linear scaling of the advance tolerance: `0.25pt at 12pt`, applied
    /// as `advanceWidthTolerancePerPoint × pointSize`.
    public static let advanceWidthTolerancePerPoint: CGFloat = 0.25 / 12.0

    // MARK: - Line banding

    /// Vertical sweep tolerance for canonical line banding: walking
    /// Y values in descending order, a gap greater than this opens a new
    /// band. Shared by the reconstructor's line pooling, the filter-side
    /// lineage walk, and the verifier's output walk so all three agree on
    /// band structure. Source line spacing in real documents is several
    /// points; sub-baseline offsets (superscripts, ordinals) sit well
    /// under 1pt — measured on the committed real-document fixture
    /// (RealDocProbeTests, 2026-06-09).
    public static let lineBandTolerance: CGFloat = 1.5

    /// Single-linkage sweep over Y values: returns each input index's band
    /// ordinal (0 = topmost). Deterministic in the input values only.
    static func yBands(_ ys: [CGFloat]) -> [Int] {
        let order = ys.indices.sorted { ys[$0] > ys[$1] }
        var band = [Int](repeating: 0, count: ys.count)
        var current = 0
        var prevY = CGFloat.nan
        for idx in order {
            if !prevY.isNaN, prevY - ys[idx] > lineBandTolerance { current += 1 }
            band[idx] = current
            prevY = ys[idx]
        }
        return band
    }

    // MARK: - Pitch quantization

    /// Pitch quantization step (J-12): band sizes round to
    /// the nearest half point. Coarser steps leak fewer content-derived
    /// bits per band and bound the doc-wide distinct-size set (measured:
    /// 17 sizes across the 23-page real-document fixture at 0.5pt).
    static let pitchQuantizationStep: CGFloat = 0.5

    /// Lower bound on a derived band size.
    static let minimumFontSize: CGFloat = 1.0

    /// True when a read-back point size is one the reconstructor's
    /// pitch derivation can emit: a whole multiple of
    /// `pitchQuantizationStep` at or above `minimumFontSize`. The
    /// Layer 6 pitch-flip acceptance gates on this so a foreign text object
    /// at an arbitrary size never reads as a writer-band junction.
    static func isWriterQuantizedPitch(_ size: CGFloat) -> Bool {
        guard size >= minimumFontSize - 0.01 else {
            return false
        }
        let steps = size / pitchQuantizationStep
        return abs(steps - steps.rounded()) * pitchQuantizationStep <= 0.01
    }

    // MARK: - Glyph core

    /// Descent fraction of a read-back font's line box —
    /// `descent / (ascent + descent)` — used to shrink read-back selection
    /// boxes to their glyph-core row (the verifier's exclusion tier and the
    /// writer's drawn-cell rule). The name mapping matches
    /// `SandwichVerification.naturalFamilyAdvance` (Menlo family →
    /// Menlo-Regular, everything else → Courier: the layer only carries
    /// accepted monospace families, Layer 8 reports any other). 0.25 without
    /// a resolvable font — at or above the accepted families' fractions
    /// (Courier 0.2465, Menlo 0.2028), so the unknown-font core is never
    /// larger than a known one.
    static func descentFraction(
        family: String?, pointSize: CGFloat
    ) -> CGFloat {
        guard let family, pointSize > 0 else { return 0.25 }
        let name = family.lowercased().contains("menlo")
            ? "Menlo-Regular" : "Courier"
        let font = CTFontCreateWithName(name as CFString, pointSize, nil)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        guard ascent + descent > 0 else { return 0.25 }
        return descent / (ascent + descent)
    }

    // MARK: - Lineage

    /// The lineage digest of an EMPTY walk — the SHA-256 of zero updates.
    /// `FilterResult.computeLineageHash(over: [])` yields exactly this for a
    /// page whose filter kept no survivor, and
    /// `SandwichVerification.computeOutputLineageHash` returns it for an
    /// output page with no text layer, no code units, or no measurable
    /// non-whitespace unit, so a fully-redacted searchable page compares
    /// equal on both sides. It is NOT `Data()`: `verifyCharacterLineage`
    /// reads an empty `Data()` as "no lineage recorded" (legacy digests,
    /// hand-built test digests) and passes without comparing.
    public static let emptyLineageDigest = Data(SHA256().finalize())

    /// Whitespace skip predicate shared by the filter-side lineage walk
    /// (`FilterResult.computeLineageHash`) and the verifier's output walk
    /// (`SandwichVerification.computeOutputLineageHash`). PDFKit's
    /// `page.string` synthesizes inter-run whitespace asymmetrically between
    /// the source (`extractCharacters`) and output (reconstructed) views;
    /// skipping whitespace on both sides keeps the hash domain a
    /// content/ordering signal (N2 residual).
    static func isLineageWhitespace(_ charString: String) -> Bool {
        guard !charString.isEmpty else { return true }
        return charString.allSatisfy { $0.isWhitespace }
    }
}
