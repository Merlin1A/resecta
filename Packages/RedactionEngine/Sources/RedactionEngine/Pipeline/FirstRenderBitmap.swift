import CoreGraphics

/// The release rule for the first-render bitmap: the context each render
/// body draws the page into is wiped when the body releases it. The image
/// handed on is `makeImage()`'s copy (the invariant `PixelBufferZeroizeTests`
/// pins), so the wipe leaves it whole.
enum FirstRenderBitmap {

    /// Test seam: observes each released context after its wipe, while the
    /// context is still alive, so a test can read its bytes. Task-local, nil
    /// in every production flow.
    @TaskLocal static var wipeProbe: (@Sendable (CGContext) -> Void)?

    /// Wipe the context's backing store, then show it to the probe.
    static func release(_ context: CGContext) {
        PixelOperations.zeroizeBitmapBuffer(context)
        wipeProbe?(context)
    }
}
