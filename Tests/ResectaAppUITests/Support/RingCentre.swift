import XCTest

/// The visible canvas band and the current match's ring, measured on a
/// screenshot, for the screen tests of the result walk. The ring is not
/// served through accessibility: its brand-teal stroke is the only teal
/// inside the canvas band on these black-on-white fixtures.
nonisolated enum RingCentre {

    static func compactStrip(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "compactFloatStrip").firstMatch
    }

    /// The visible canvas band: from the toolbar's bottom edge to the
    /// parked sheet's top (the strip's frame less the grabber inset).
    static func canvasBand(_ app: XCUIApplication) -> ClosedRange<CGFloat> {
        let navBar = app.navigationBars.firstMatch
        let top: CGFloat = navBar.exists ? navBar.frame.maxY : 116
        // The page bar steps aside while the walk is parked; were it up,
        // the visible canvas would end at it (its teal chevron must not
        // join the ring's box).
        let pageBar = app.descendants(matching: .any).matching(identifier: "pageNav").firstMatch
        let floor = pageBar.exists ? pageBar.frame.minY : compactStrip(app).frame.minY
        let bottom = floor - 14
        return top...bottom
    }

    /// The bounding box (screen points) of brand-teal pixels inside the
    /// band, or nil when none.
    static func ringBox(in band: ClosedRange<CGFloat>, windowWidth: CGFloat) throws -> CGRect? {
        let image = XCUIScreen.main.screenshot().image
        guard let cg = image.cgImage, let provider = cg.dataProvider, let data = provider.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let scale = CGFloat(cg.width) / windowWidth
        let bytesPerRow = cg.bytesPerRow, bytesPerPixel = cg.bitsPerPixel / 8
        let alphaFirst = cg.alphaInfo == .premultipliedFirst || cg.alphaInfo == .first || cg.alphaInfo == .noneSkipFirst
        let littleEndian = cg.bitmapInfo.contains(.byteOrder32Little)
        // BGRA (little-endian, alpha first) vs RGBA (big-endian, alpha last).
        let rOffset = (littleEndian && alphaFirst) ? 2 : 0
        let bOffset = (littleEndian && alphaFirst) ? 0 : 2
        let y0 = max(0, Int(band.lowerBound * scale)), y1 = min(cg.height, Int(band.upperBound * scale))
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        var y = y0
        while y < y1 {
            var x = 0
            while x < cg.width {
                let p = y * bytesPerRow + x * bytesPerPixel
                let r = Int(bytes[p + rOffset]), g = Int(bytes[p + 1]), b = Int(bytes[p + bOffset])
                if b - r > 50 && g - r > 50 && r < 90 && g >= 70 && g <= 175 && b >= 80 && b <= 190 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
                x += 2
            }
            y += 2
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX) / scale, height: CGFloat(maxY - minY) / scale)
    }

    /// The ring's centre within 12 pt of `expected` (screen points), which
    /// is worked out from the band and the ring's box; the ring's box, or
    /// nil (and a failure) when no ring is found.
    @discardableResult
    static func assertRingCentred(_ app: XCUIApplication, step: String,
                                  expected: (ClosedRange<CGFloat>, CGRect, CGRect) -> CGPoint,
                                  file: StaticString = #filePath, line: UInt = #line) throws -> CGRect? {
        sleep(2)
        let band = canvasBand(app)
        let window = app.windows.firstMatch.frame
        guard let ring = try ringBox(in: band, windowWidth: window.width) else {
            XCTFail("Step \(step): no teal ring found in the canvas band \(band).", file: file, line: line)
            return nil
        }
        let want = expected(band, window, ring)
        XCTAssertLessThanOrEqual(abs(ring.midY - want.y), 12, "Step \(step): ring centre y \(ring.midY) is off the expected \(want.y).", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(ring.midX - want.x), 12, "Step \(step): ring centre x \(ring.midX) is off the expected \(want.x).", file: file, line: line)
        return ring
    }

    /// The visible canvas's centre: where a step puts the ring when the
    /// page-edge clamp does not bind.
    static func bandCentre(_ band: ClosedRange<CGFloat>, _ window: CGRect, _ ring: CGRect) -> CGPoint {
        CGPoint(x: window.midX, y: (band.lowerBound + band.upperBound) / 2)
    }
}
