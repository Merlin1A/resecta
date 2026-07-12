import Foundation
import ImageIO
import CoreGraphics

// SEC-8 prereq (plan §3): Live Photo / Portrait depth auxiliary-metadata stripper.
//
// Locked decision: this helper drops `kCGImagePropertyAuxiliaryData` keys,
// `kCGImagePropertyMakerAppleDictionary`, and a peer-key denylist from the
// image-properties dictionary. V1 strips the property dict only — the
// `CGImage` is returned unchanged, since stripping aux data from the image
// itself would require re-encoding (heavier change, out of scope here).
// SEC-8 (unit 23) will flip the import-path gate when paranoid mode is
// enabled.
//
// **Where the actual aux-metadata gate lives.** Package H header note,
// per `03-security-perf-audit.md §3.3.a`. The mechanism preventing aux
// metadata from reaching the export PDF is
// `UIGraphicsPDFRenderer.pdfData` in
// `Sources/ResectaApp/Views/ImportService.swift renderImageAsPDF(...)`,
// which does not carry the ImageIO property dictionary into the rendered
// PDF stream. This helper is **defense-in-depth**: if the import path
// ever switches to a `CGImageDestination`-based PDF writer (or any other
// renderer that *does* propagate the property dict), the denylist below
// remains a meaningful filter and the SEC-8 contract continues to hold at
// the source. The pairing is recorded in `ARCHITECTURE.md §1.2 SEC-8`.
//
// Mechanism-description language (I6 / ARCH §1.3): this helper is designed
// to reduce the surface area of camera-origin metadata that could be
// carried into the export pipeline. It is a best-effort metadata filter.

/// Strips Live Photo / Portrait depth auxiliary-metadata keys from an image's
/// property dictionary. The `CGImage` is returned unchanged in V1.
///
/// Property dictionary keys removed (each is removed only if present):
/// - `kCGImagePropertyAuxiliaryData` — top-level container for ImageIO
///   auxiliary data attachments (depth maps, portrait effects mattes, etc.).
/// - `kCGImagePropertyMakerAppleDictionary` — Apple maker-note metadata that
///   includes Live Photo identifiers and other camera-pipeline state.
/// - `kCGImagePropertyGPSDictionary` — GPS coordinates and altitude.
/// - `kCGImagePropertyExifDictionary` — EXIF (capture date/time, device
///   model, lens, software, exposure parameters).
/// - `kCGImagePropertyTIFFDictionary` — TIFF (camera make/model, software).
/// - `kCGImagePropertyIPTCDictionary` — IPTC headlines / captions /
///   keywords / by-line fields.
/// - `kCGImageAuxiliaryDataTypeDepth` (peer key if present at top level).
/// - `kCGImageAuxiliaryDataTypeDisparity` — Portrait Mode disparity peer.
/// - `kCGImageAuxiliaryDataTypePortraitEffectsMatte` (peer key).
/// - `kCGImageAuxiliaryDataTypeHDRGainMap` — HDR gain map (iOS 14.1+).
/// - `kCGImageAuxiliaryDataTypeISOGainMap` — ISO gain map (iOS 17+).
/// - `kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte`
/// - `kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte`
/// - `kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte`
/// - `kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte`
///
/// Other keys (e.g. `kCGImagePropertyOrientation`, color space, dimensions)
/// pass through unchanged.
// nonisolated: pure stateless aux-data stripper invoked from the
// `nonisolated` off-main import path (ImportService.loadImageOffMainActor).
// Restores the effective isolation it had before SE-0466 MainActor-default
// was pinned project-wide (fix-series s04 flip) — no MainActor state touched.
nonisolated public struct LivePhotoAuxStripper: Sendable {

    public init() {}

    /// Keys removed by `strip(_:properties:)`. Exposed for tests and for any
    /// caller that wants to assert denylist coverage against the SEC-8
    /// contract in `ARCHITECTURE.md §1.2`. Computed (rather than stored
    /// static `let`) because `CFString` is not `Sendable` in Swift 6 strict
    /// mode; the returned array is a fresh value per access.
    public static var denylist: [CFString] {
        [
            // Top-level aux-data container.
            kCGImagePropertyAuxiliaryData,
            // Apple maker-note dictionary (carries Live Photo identifiers).
            kCGImagePropertyMakerAppleDictionary,
            // Geo / EXIF / TIFF / IPTC property dictionaries.
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyExifDictionary,
            kCGImagePropertyTIFFDictionary,
            kCGImagePropertyIPTCDictionary,
            // Peer aux-data type keys.
            kCGImageAuxiliaryDataTypeDepth,
            kCGImageAuxiliaryDataTypeDisparity,
            kCGImageAuxiliaryDataTypePortraitEffectsMatte,
            kCGImageAuxiliaryDataTypeHDRGainMap,
            kCGImageAuxiliaryDataTypeISOGainMap,
            kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
        ]
    }

    /// Returns the image unchanged plus a property dictionary with the
    /// Live Photo / Portrait depth auxiliary-metadata keys removed.
    public func strip(
        _ image: CGImage,
        properties: CFDictionary
    ) -> (CGImage, CFDictionary) {
        // Copy into a mutable Swift dictionary keyed by CFString so we can
        // remove the targeted entries without mutating the caller's CFDictionary.
        let bridged = properties as? [CFString: Any] ?? [:]
        var mutable = bridged

        // Drop each denylisted key if present; `removeValue` is a no-op for
        // missing keys, so the helper is idempotent on already-clean dicts.
        for key in Self.denylist {
            mutable.removeValue(forKey: key)
        }

        let cleaned = mutable as CFDictionary
        return (image, cleaned)
    }
}
