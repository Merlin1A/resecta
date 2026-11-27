#if DEBUG
import PDFKit
import UIKit

// The test-only read-out of a `FitFlooredPDFView`: where the shown page is
// on screen, read from PDFKit, for a screen test that compares the editor's
// boxes with the file the run writes. Present only under `--canvasReadOut`
// in a DEBUG build; the editor's canvas and the preview are both this class,
// so one override serves both.
//
// One line, computed when asked, fields joined by "; ":
//
//   page=<index>; scale=<scaleFactor>; fit=<scaleFactorForSizeToFit>;
//   origin=<x>,<y>; size=<width>,<height>; contrast=<0|1>;
//   transparency=<0|1>; picture=<width>x<height>|none[; probe=<c>:<n>,...]
//
// - origin: the top-left corner, in window points, of the current page as
//   displayed (its bounds for the display box, through `convert(_:from:)`,
//   then to the window).
// - size: that page's displayed size in points (its sides swapped on a page
//   turned a quarter).
// - contrast, transparency: Increase Contrast and Reduce Transparency, as
//   UIKit reports them.
// - picture: the size in pixels of the one picture the page's resources
//   hold, read from the file; "none" when it holds none or several. A page
//   the run writes is one picture drawn into the page.
// - probe: under `--canvasReadOutProbe=<characters>`, for each character,
//   how many literal matches the shown document's text has.
//
// Numbers are written in full, as Swift describes a Double.

extension FitFlooredPDFView {
    static let readOutIsOn = ProcessInfo.processInfo.arguments.contains("--canvasReadOut")

    static let readOutProbe: String? = ProcessInfo.processInfo.arguments
        .first { $0.hasPrefix("--canvasReadOutProbe=") }
        .map { String($0.dropFirst("--canvasReadOutProbe=".count)) }

    func readOut() -> String {
        guard let page = currentPage, let document else { return "page=none" }
        let shown = convert(convert(page.bounds(for: displayBox), from: page), to: nil)
        let bounds = page.bounds(for: displayBox)
        let quarter = (page.rotation / 90) % 2 != 0
        let size = quarter ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        var fields = [
            "page=\(document.index(for: page))",
            "scale=\(Double(scaleFactor))",
            "fit=\(Double(scaleFactorForSizeToFit))",
            "origin=\(Double(shown.minX)),\(Double(shown.minY))",
            "size=\(Double(size.width)),\(Double(size.height))",
            "contrast=\(UIAccessibility.isDarkerSystemColorsEnabled ? 1 : 0)",
            "transparency=\(UIAccessibility.isReduceTransparencyEnabled ? 1 : 0)",
            "picture=" + (Self.pictureSize(of: page).map { "\($0.width)x\($0.height)" } ?? "none"),
        ]
        if let probe = Self.readOutProbe, !probe.isEmpty {
            let counts = probe.map { character in
                "\(character):\(document.findString(String(character), withOptions: .literal).count)"
            }
            fields.append("probe=" + counts.joined(separator: ","))
        }
        return fields.joined(separator: "; ")
    }

    /// The size in pixels of the one picture `page`'s resources hold, read
    /// through the page's own `CGPDFPage`; nil when they hold none or more
    /// than one, or the page has no resources to read.
    static func pictureSize(of page: PDFPage) -> (width: Int, height: Int)? {
        guard let dictionary = page.pageRef?.dictionary else { return nil }
        var resources: CGPDFDictionaryRef?
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return nil }
        var sizes: [(width: Int, height: Int)] = []
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let info = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            var width: CGPDFInteger = 0
            var height: CGPDFInteger = 0
            guard CGPDFDictionaryGetName(info, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Image",
                  CGPDFDictionaryGetInteger(info, "Width", &width),
                  CGPDFDictionaryGetInteger(info, "Height", &height) else { return true }
            sizes.append((Int(width), Int(height)))
            return true
        }, nil)
        return sizes.count == 1 ? sizes[0] : nil
    }
}
#endif
