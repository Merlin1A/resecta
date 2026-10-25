import CoreGraphics
import Foundation
import PDFKit

// Which pages the ink fit runs on (`DocumentSearcher+InkFit.swift`): a page-scale
// image under text shown in an invisible render mode.

extension DocumentSearcher {
    /// A page-scale image under text shown in an invisible render mode: the
    /// page's glyphs leave no ink of their own (a hidden layer over a picture
    /// of the page). Read once per page.
    nonisolated static func carriesHiddenTextOverImage(_ page: PDFPage, cgPage: CGPDFPage) -> Bool {
        if let known = HiddenTextOverImageCache.shared.value(for: page) { return known }
        let answer = carriesPageScaleImage(page, cgPage: cgPage) && showsInvisibleText(cgPage)
        HiddenTextOverImageCache.shared.set(answer, for: page)
        return answer
    }

    /// An image object covering at least `PageImageCensus.imageShareFloor` of
    /// the crop box: the page is a picture with a text layer over it.
    nonisolated static func carriesPageScaleImage(_ page: PDFPage, cgPage: CGPDFPage) -> Bool {
        guard let pixels = PageImageCensus.largestImagePixelArea(of: cgPage) else { return false }
        return PageImageCensus.imageShare(pixelArea: pixels, cropBox: page.bounds(for: .cropBox))
            >= PageImageCensus.imageShareFloor
    }

    /// Whether the page's content shows text in render mode 3 or 7 (no fill,
    /// no stroke): `Tr` tracked through `q`/`Q` and into Form XObjects (to a
    /// depth of 8), any text-showing operator while it is set answers true. A
    /// stream the scanner cannot read, or a form chain past the depth, answers
    /// true as well: a page not known to be clean is fitted.
    nonisolated static func showsInvisibleText(_ cgPage: CGPDFPage) -> Bool {
        final class State {
            var mode: Int = 0
            var saved: [Int] = []
            var found = false
            var depth = 0
            var table: CGPDFOperatorTableRef?
        }
        guard let table = CGPDFOperatorTableCreate() else { return true }
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
            guard state.depth < 8, let table = state.table else { state.found = true; CGPDFScannerStop(scanner); return }
            var resources: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            let inner = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, content)
            let innerScanner = CGPDFScannerCreate(inner, table, info)
            let mode = state.mode
            state.depth += 1
            if !CGPDFScannerScan(innerScanner) && !state.found { state.found = true }
            state.depth -= 1
            state.mode = mode
            CGPDFScannerRelease(innerScanner)
            CGPDFContentStreamRelease(inner)
            if state.found { CGPDFScannerStop(scanner) }
        }
        let state = State()
        state.table = table
        let content = CGPDFContentStreamCreateWithPage(cgPage)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
        let read = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        return state.found || !read
    }
}
