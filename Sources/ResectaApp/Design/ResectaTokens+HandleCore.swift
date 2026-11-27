import CoreGraphics

// nonisolated: a pure size, usable from any isolation, as the canvas
// tokens it sits beside are.
nonisolated extension ResectaTokens.Canvas {
    /// The core of a drawn handle of the selected box: a square this many
    /// on-screen points wide, centred on the handle, where that handle
    /// takes the touch even over another box's body.
    static let handleCore: CGFloat = 22
}
