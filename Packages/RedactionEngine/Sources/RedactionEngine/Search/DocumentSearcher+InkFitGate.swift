import CoreGraphics
import Foundation
import PDFKit

// Which pages the ink fit runs on (`DocumentSearcher+InkFit.swift`): pages whose
// text does not sit on its own print. Either the page shows text in an invisible
// render mode and its print is a picture, or text it shows in a visible mode lies
// under pictures that hide it, or it draws a picture and its painting cannot be
// followed.

extension DocumentSearcher {
    /// Whether the fit runs on the page: (1) it shows text in an invisible mode
    /// and its print is a picture, or (2) text it shows in a visible mode lies
    /// under pictures painted after it that hide it, or (3) it draws a picture
    /// and its painting cannot be followed. Where pictures are painted is read
    /// only for a page the answer depends on. Read once per page.
    nonisolated static func carriesHiddenTextOverImage(_ page: PDFPage, cgPage: CGPDFPage) -> Bool {
        if let known = HiddenTextOverImageCache.shared.value(for: page) { return known }
        let invisible = showsInvisibleText(cgPage)
        let pageScale = carriesPageScaleImage(page, cgPage: cgPage)
        // The last facts matter only without invisible text, and each only
        // when the ones before it found no picture: they are read only then.
        let reaches = !invisible && PageImageCensus.largestImagePixelArea(of: cgPage) != nil
        let inline = !invisible && !reaches && PageContentFacts.drawsInlineImage(cgPage)
        // A picture inside a tiling pattern is seen by neither fact above.
        let patterned = !invisible && !reaches && !inline && PictureWalk.patternsHoldPicture(cgPage)
        let answer: Bool
        if needsPictureMap(showsInvisibleText: invisible, largestImageIsPageScale: pageScale,
                           reachesImage: reaches || patterned, drawsInlineImage: inline) {
            answer = invisible ? printIsAPicture(pageScale: pageScale, page: page, cgPage: cgPage)
                : Self.visibleTextIsHidden(PagePictureMap.cached(page, cgPage: cgPage))
        } else {
            answer = invisible && pageScale
        }
        HiddenTextOverImageCache.shared.set(answer, for: page)
        return answer
    }

    /// Why the fit takes the page, as the account of what was read tells it;
    /// nil when it does not. A page whose largest image is page-scale, or
    /// whose painting was followed, has another app's text over a picture of
    /// it; a page taken while its painting cannot be followed has that reason
    /// alone, since where its print lies is not known.
    enum FitReason: Equatable, Sendable { case anotherAppsText, paintingNotFollowed }

    nonisolated static func fitReason(_ page: PDFPage, cgPage: CGPDFPage) -> FitReason? {
        guard carriesHiddenTextOverImage(page, cgPage: cgPage) else { return nil }
        if carriesPageScaleImage(page, cgPage: cgPage) { return .anotherAppsText }
        return PagePictureMap.cached(page, cgPage: cgPage).followed ? .anotherAppsText : .paintingNotFollowed
    }

    /// A page with no invisible text that draws a picture: its visible text
    /// lies under pictures that hide it, or its painting cannot be followed,
    /// so where its print lies is not known.
    nonisolated static func visibleTextIsHidden(_ map: PagePictureMap) -> Bool {
        !map.followed || map.hidesVisibleText
    }

    /// Whether a page fitted only by the wider gate (its pictures cover it, or
    /// its visible text lies under them) gets a plan for its hidden words when
    /// it carries a box not placed from its text. With true, such a page keeps
    /// its text layer less the words the plan holds, as a page whose one image
    /// is page-scale does; with false, it is written as a picture.
    static let drawnBoxOnNewlyFittedPageKeepsTextLayer: Bool = false

    /// Whether the hidden-word plan is made for a page: always on a page the
    /// fit took before the gate was widened; on a page only the wider gate
    /// takes, unless it carries a box not placed from its text and such a box
    /// is to leave the page a picture.
    nonisolated static func planIsMade(fittedToday: Bool, fittedByWiderGate: Bool, hasUnanchoredBox: Bool,
                                       drawnBoxKeepsTextLayer: Bool) -> Bool {
        fittedToday || (fittedByWiderGate && (!hasUnanchoredBox || drawnBoxKeepsTextLayer))
    }

    /// Whether the gate's answer depends on where the page's pictures are
    /// painted: a page with invisible text and no page-scale image, or a page
    /// with no invisible text that draws a picture at all.
    nonisolated static func needsPictureMap(showsInvisibleText: Bool, largestImageIsPageScale: Bool,
                                            reachesImage: Bool, drawsInlineImage: Bool) -> Bool {
        (showsInvisibleText && !largestImageIsPageScale) || (!showsInvisibleText && (reachesImage || drawsInlineImage))
    }

    /// Whether the page's print is a picture: its largest image is page-scale,
    /// or its pictures as painted cover the page by the map's line, or its
    /// painting cannot be followed. The call for whoever builds the plan's
    /// page facts (`PageTextFacts`).
    nonisolated static func printIsAPicture(_ page: PDFPage, cgPage: CGPDFPage) -> Bool {
        printIsAPicture(pageScale: carriesPageScaleImage(page, cgPage: cgPage), page: page, cgPage: cgPage)
    }

    /// `printIsAPicture` with the largest-image answer already read.
    nonisolated static func printIsAPicture(pageScale: Bool, page: PDFPage, cgPage: CGPDFPage) -> Bool {
        if pageScale { return true }
        let map = PagePictureMap.cached(page, cgPage: cgPage)
        return !map.followed || map.coversThePage
    }

    /// An image object covering at least `PageImageCensus.imageShareFloor` of
    /// the crop box: the page is a picture with a text layer over it.
    nonisolated static func carriesPageScaleImage(_ page: PDFPage, cgPage: CGPDFPage) -> Bool {
        guard let pixels = PageImageCensus.largestImagePixelArea(of: cgPage) else { return false }
        return PageImageCensus.imageShare(pixelArea: pixels, cropBox: page.bounds(for: .cropBox))
            >= PageImageCensus.imageShareFloor
    }

    /// Whether the page's content shows text in render mode 3 or 7 (no fill,
    /// no stroke), or could not be read: a page not known to be clean is
    /// fitted. The walk is `invisibleTextReading`.
    nonisolated static func showsInvisibleText(_ cgPage: CGPDFPage) -> Bool {
        invisibleTextReading(cgPage) != .showsNone
    }

    /// The page's content read for text in render mode 3 or 7: `Tr` tracked
    /// through `q`/`Q` and into Form XObjects (to a depth of 8); any
    /// text-showing operator while it is set reads `shows`. A stream the
    /// scanner cannot read, a form chain past the depth, or more than
    /// `PagePictureMap.formLimit` forms drawn, reads `unreadable`; the walk
    /// stops at the first of the two.
    nonisolated static func invisibleTextReading(_ cgPage: CGPDFPage) -> InvisibleTextReading {
        final class State {
            var mode: Int = 0
            var saved: [Int] = []
            var found = false
            var unreadable = false
            var depth = 0
            var drawn = 0
            var table: CGPDFOperatorTableRef?
        }
        guard let table = CGPDFOperatorTableCreate() else { return .unreadable }
        defer { CGPDFOperatorTableRelease(table) }
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            var value: CGPDFInteger = 0
            guard let info, CGPDFScannerPopInteger(scanner, &value) else { return }
            Unmanaged<State>.fromOpaque(info).takeUnretainedValue().mode = Int(value)
        }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let info else { return }
            let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            state.saved.append(state.mode)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let info else { return }
            let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            if let mode = state.saved.popLast() { state.mode = mode }
        }
        let show: CGPDFOperatorCallback = { scanner, info in
            guard let info else { return }
            let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            if state.mode == 3 || state.mode == 7 { state.found = true; CGPDFScannerStop(scanner) }
        }
        for op in ["Tj", "TJ", "'", "\""] { CGPDFOperatorTableSetCallback(table, op, show) }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let info else { return }
            let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let content = CGPDFScannerGetContentStream(scanner)
            var stream: CGPDFStreamRef?
            guard let object = CGPDFContentStreamGetResource(content, "XObject", name),
                  CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Form" else { return }
            state.drawn += 1
            guard state.depth < 8, state.drawn <= PagePictureMap.formLimit, let table = state.table else {
                state.unreadable = true; CGPDFScannerStop(scanner); return
            }
            var resources: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            let inner = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, content)
            let innerScanner = CGPDFScannerCreate(inner, table, info)
            let mode = state.mode
            state.depth += 1
            if !CGPDFScannerScan(innerScanner) && !state.found && !state.unreadable { state.unreadable = true }
            state.depth -= 1
            state.mode = mode
            CGPDFScannerRelease(innerScanner)
            CGPDFContentStreamRelease(inner)
            if state.found || state.unreadable { CGPDFScannerStop(scanner) }
        }
        let state = State()
        state.table = table
        let content = CGPDFContentStreamCreateWithPage(cgPage)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
        let read = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        if state.found { return .shows }
        return state.unreadable || !read ? .unreadable : .showsNone
    }
}
