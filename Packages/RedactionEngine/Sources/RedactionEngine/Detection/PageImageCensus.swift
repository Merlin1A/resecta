import Foundation
import PDFKit
import CoreGraphics

/// Whether a page with a text layer also carries content its text layer does
/// not hold. The page must reach an image object, and either the image covers
/// at least half the page at 100 dpi (a scan under a stamp or a vendor text
/// layer, a pasted photo of an ID), or the text layer is too thin for the page
/// (fewer than about 200 characters on a letter page: a Bates line, a court
/// header or a stamp over a scan placed small). A page with no image object
/// carries nothing to recognise beyond its text layer, however short. Search
/// reads such a page on both legs; its text-layer status is unchanged.
///
/// The two floors were set from a census of the sample corpus (543 pages in
/// 35 documents): no page with a text layer carries an image object at all,
/// and the thinnest carries 1,004 characters (2,071 per 10⁶ pt²), five times
/// the density floor.
enum PageImageCensus {

    /// The share of the page's pixel area at 100 dpi an image object must cover.
    static let imageShareFloor = 0.5
    /// Meaningful characters per 10⁶ pt² below which a text layer reads as a stamp alone.
    static let densityFloor = 410.0
    /// Bound on form objects nested inside one another.
    static let maxFormDepth = 8

    /// The census rule for one page. A page with no visible area carries nothing.
    static func carriesImageContent(_ page: PDFPage) -> Bool {
        let crop = page.bounds(for: .cropBox)
        guard crop.width > 0, crop.height > 0 else { return false }
        guard let cgPage = page.pageRef, let pixels = largestImagePixelArea(of: cgPage) else { return false }
        if imageShare(pixelArea: pixels, cropBox: crop) >= imageShareFloor { return true }
        let meaningful = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count
        return textDensity(meaningfulCount: meaningful, cropBox: crop) < densityFloor
    }

    static func textDensity(meaningfulCount: Int, cropBox: CGRect) -> Double {
        Double(meaningfulCount) / Double(cropBox.width * cropBox.height) * 1_000_000
    }

    static func imageShare(pixelArea: Int, cropBox: CGRect) -> Double {
        Double(pixelArea) / (Double(cropBox.width * cropBox.height) * pow(100.0 / 72.0, 2))
    }

    /// The largest image object's `/Width` × `/Height` among those the page's
    /// resources (own or inherited) reach, through form objects to
    /// `maxFormDepth`; nil when the page reaches none. Each stream is read once
    /// (a form that draws itself ends the walk).
    static func largestImagePixelArea(of page: CGPDFPage) -> Int? {
        guard let dictionary = page.dictionary,
              case .found(let resources) = TextLayerExtractor.inheritedResources(of: dictionary) else { return nil }
        var visited = Set<CGPDFStreamRef>()
        return largestImage(in: resources, depth: 0, visited: &visited)
    }

    private static func largestImage(
        in resources: CGPDFDictionaryRef, depth: Int, visited: inout Set<CGPDFStreamRef>
    ) -> Int? {
        guard depth < maxFormDepth else { return nil }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return nil }
        var streams: [CGPDFStreamRef] = []
        CGPDFDictionaryApplyBlock(xobjects, { _, value, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(value, .stream, &stream), let stream { streams.append(stream) }
            return true
        }, nil)
        var largest: Int?
        for stream in streams where !visited.contains(stream) {
            visited.insert(stream)
            guard let dictionary = CGPDFStreamGetDictionary(stream) else { continue }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { continue }
            var area: Int?
            switch String(cString: subtype) {
            case "Image":
                var width: CGPDFInteger = 0
                var height: CGPDFInteger = 0
                if CGPDFDictionaryGetInteger(dictionary, "Width", &width),
                   CGPDFDictionaryGetInteger(dictionary, "Height", &height), width > 0, height > 0 {
                    area = Int(width) * Int(height)
                }
            case "Form":
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Resources", &inner), let inner {
                    area = largestImage(in: inner, depth: depth + 1, visited: &visited)
                }
            default:
                break
            }
            if let area, area > (largest ?? 0) { largest = area }
        }
        return largest
    }
}
