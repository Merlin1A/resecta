import CoreGraphics
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
import os

// Page memory policy: the resolution tier a page renders at under the
// device's memory, and the pre-render checks (geometry, memory) every
// page passes before the rasterizer draws it.

// MARK: - DPI Selection

/// Select the effective DPI for a page, respecting both the user's
/// chosen maximum and the device's available memory.
/// Returns nil if even 150 DPI exceeds available memory (abort).
/// Page dimensions default to US Letter for backward compatibility;
/// callers should pass actual dimensions for large-format pages.
public func selectDPI(
    availableMemory: Int,
    userMaxDPI: Int,
    pageWidth: CGFloat = 612,
    pageHeight: CGFloat = 792
) -> Int? {
    let clampedMax = [150, 200, 300].filter { $0 <= userMaxDPI }.max() ?? 150
    // 150 MB headroom. Floor at 0 for constrained devices
    // where availableMemory <= 150 MB — the tier loop returns nil gracefully.
    let budget = max(0, availableMemory - 150_000_000)
    // Compute actual memory needed at each DPI tier based on page dimensions.
    // The tier test budgets TWO bitmaps per page (the render and the fill
    // contexts); the admission predicate below budgets three.
    let tiers = [300, 200, 150].filter { $0 <= clampedMax }
    for dpi in tiers {
        let scale = CGFloat(dpi) / 72.0
        let bytes = Int(ceil(pageWidth * scale)) * Int(ceil(pageHeight * scale)) * 4
        if bytes * 2 < budget { return dpi }
    }
    return nil
}

// MARK: - Input Validation

/// Validate a page before rendering: the geometry half
/// (`validatePageGeometry`) and the memory half (`validatePageMemory`)
/// together. Kept as the one-call form for callers and tests that only
/// need the combined verdict; `PageRasterizer.rasterize` calls the two
/// halves separately so each refusal carries its own error case.
func validatePage(_ page: PDFPage, effectiveDPI: Int = 300) -> Bool {
    validatePageGeometry(page) && validatePageMemory(page, effectiveDPI: effectiveDPI)
}

/// The geometry half of the pre-flight: every side of the cropBox between
/// 10 and 5,000 pt, no non-default `/UserUnit` on the page dictionary, and a
/// `/Rotate` that is a right angle read the same way by PDFKit and by
/// CoreGraphics. Independent of DPI and of available memory. A page that
/// fails here is reported as `.unsupportedPageGeometry`, never as a memory
/// failure.
func validatePageGeometry(_ page: PDFPage) -> Bool {
    let box = page.bounds(for: .cropBox)
    guard box.width >= 10, box.height >= 10,
          box.width <= 5000, box.height <= 5000 else { return false }

    if let pageRef = page.pageRef {
        // Check for /UserUnit (Experiment N)
        if let dict = pageRef.dictionary {
            var userUnit: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(dict, "UserUnit", &userUnit),
               userUnit != 1.0 {
                return false
            }
        }
        // A /Rotate that is not a right angle (invalid per ISO 32000
        // section 7.7.3.3, still opened) is rounded by PDFKit — the frame of the
        // editor, text extraction, search and every region — while
        // CoreGraphics keeps the raw value, so a render would place every
        // fill on the wrong pixels. Refuse unless both read the same
        // right angle (an inherited /Rotate resolves in both).
        let raw = ((Int(pageRef.rotationAngle) % 360) + 360) % 360
        let displayed = ((page.rotation % 360) + 360) % 360
        guard raw % 90 == 0, raw == displayed else { return false }
    }
    return true
}

/// The memory half of the pre-flight: the page's raster at `effectiveDPI`
/// must fit the three-bitmap estimate against available memory. The
/// rasterizer runs the geometry half first, so an out-of-range page never
/// reaches this estimate; called alone, an oversized page's estimate is
/// simply large.
func validatePageMemory(_ page: PDFPage, effectiveDPI: Int = 300) -> Bool {
    let box = page.bounds(for: .cropBox)

    // Use effective DPI for memory budget check.
    let scale: CGFloat = CGFloat(effectiveDPI) / 72.0
    let bytes = Int(ceil(box.width * scale)) * Int(ceil(box.height * scale)) * 4

    // Measured 2026-06-13: `os_proc_available_memory()` is unusable
    // on the simulator — it reports well under 67 MB regardless of real
    // headroom, so a standard page's 300-DPI raster (~33.7 MB) fails the
    // fraction-of-available test and the validatePage wire-up would then refuse every page.
    // When the reading is at or below the 150 MB headroom — the same
    // floor at which `selectDPI` yields zero budget — treat it as unusable and
    // defer the memory decision to the runtime DPI cap + `selectDPI` (KI-5),
    // which are the effective memory defense. The geometry half
    // (`validatePageGeometry`) runs first in every case, so the pre-flight
    // keeps rejecting out-of-range pages.
    #if canImport(UIKit)
    let available = os_proc_available_memory()
    guard available > 150_000_000 else { return true }
    return pageMemoryEstimateFits(oneBitmapBytes: bytes, available: Int(available))
    #else
    // macOS tooling destination: os_proc_available_memory() is iOS-only.
    // Treat the reading as unusable — the same outcome as the simulator
    // case above — and defer to the runtime DPI cap + `selectDPI`.
    _ = bytes
    return true
    #endif
}

/// The per-page memory admission predicate: a page is admitted
/// when THREE bitmaps' worth of its raster fit in available memory — the same
/// per-page estimate the app layer budgets (render context + pooled fill
/// context + encode buffer, `PipelineCoordinator`'s
/// `pixelW * pixelH * 4 * 3`). Extracted so the constant is host-testable;
/// `validatePage`'s deferral branches above are unchanged.
@inlinable
internal func pageMemoryEstimateFits(oneBitmapBytes: Int, available: Int) -> Bool {
    oneBitmapBytes < available / 3
}
