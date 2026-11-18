import CoreGraphics
import CryptoKit
import Foundation

// Each page has exactly one page image: the one image stream the system
// reader reports for it. It is accepted when its SHA-256 equals the value
// recorded for that page as the app handed the picture to the writer, and
// those bytes occur in the checked file. Pages with equal recorded hashes may
// share one occurrence of the bytes; ranges of different streams never
// overlap. No image on a page, or two, is a refusal. No record of the run is
// one answer for the whole document, never "nothing to check".

/// One image stream a page draws, as the system reader hands it over.
struct PageImageStream: Sendable {
    /// The stream's bytes with every filter but the picture's own undone.
    let bytes: Data
    /// True when those bytes are a JPEG (the stream's last filter is DCT).
    let isJPEG: Bool
}

/// Where a page's image streams come from. One conformer in 1.4.0, the
/// system reader; a later one changes nothing else.
protocol PageImageSource {
    var pageCount: Int { get }
    /// Every image the page draws, its own and those of the forms it draws.
    func images(onPage index: Int) -> [PageImageStream]
}

/// The system reader: Core Graphics' own reading of the checked file.
struct SystemPageImageSource: PageImageSource {
    private let document: CGPDFDocument

    /// Forms within forms are followed this deep, no deeper.
    static let formDepthLimit = 8

    init?(fileData: Data) {
        guard let provider = CGDataProvider(data: fileData as CFData),
              let document = CGPDFDocument(provider) else { return nil }
        self.document = document
    }

    var pageCount: Int { document.numberOfPages }

    func images(onPage index: Int) -> [PageImageStream] {
        guard let page = document.page(at: index + 1), let dict = page.dictionary else { return [] }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let res = resources else { return [] }
        var found: [PageImageStream] = []
        Self.collect(res, depth: 0, into: &found)
        return found
    }

    private static func collect(_ resources: CGPDFDictionaryRef, depth: Int, into found: inout [PageImageStream]) {
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobj = xobjects else { return }
        var streams: [CGPDFStreamRef] = []
        CGPDFDictionaryApplyBlock(xobj, { _, value, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(value, .stream, &stream), let s = stream { streams.append(s) }
            return true
        }, nil)
        for s in streams {
            guard let d = CGPDFStreamGetDictionary(s) else { continue }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(d, "Subtype", &subtype), let name = subtype.map({ String(cString: $0) }) else { continue }
            if name == "Image" {
                var format = CGPDFDataFormat.raw
                let data = CGPDFStreamCopyData(s, &format).map { $0 as Data } ?? Data()
                found.append(PageImageStream(bytes: data, isJPEG: format == .jpegEncoded))
            } else if name == "Form", depth < formDepthLimit {
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(d, "Resources", &inner), let r = inner {
                    collect(r, depth: depth + 1, into: &found)
                }
            }
        }
    }
}

enum PageImageLocator {

    /// Reads every page's picture, one page at a time, and hands each page's
    /// outcome to `body` as it is made, so a page's block table can be freed
    /// when the page is done. `recordedHashes` holds one SHA-256 a page, as
    /// recorded when the app handed that page's picture to the writer; nil
    /// when the run has no record, which is one answer for the document.
    /// Returns false, having read nothing, when there is no record.
    @discardableResult
    static func readEach(fileData: Data, source: some PageImageSource, recordedHashes: [Data]?,
                         _ body: (Int, PageImageOutcome) -> Void) throws(CancellationError) -> Bool {
        guard let recordedHashes else { return false }
        var located: [Data: Range<Int>] = [:]
        var claimed: [Range<Int>] = []
        var cursor = 0
        for index in 0..<source.pageCount {
            if Task.isCancelled { throw CancellationError() }
            let outcome: PageImageOutcome
            switch accept(index, fileData: fileData, source: source, recordedHashes: recordedHashes,
                          located: &located, claimed: &claimed, cursor: &cursor) {
            case .failure(let refusal): outcome = .couldNotFinish(refusal)
            case .success(let bytes):
                switch try JPEGEntropyWalk.walk(bytes) {
                case .success(let walk): outcome = .completed(walk)
                case .failure(let refusal): outcome = .couldNotFinish(refusal)
                }
            }
            body(index, outcome)
        }
        return true
    }

    /// Every page's outcome together: for a caller that keeps them all.
    static func read(fileData: Data, source: some PageImageSource, recordedHashes: [Data]?) throws(CancellationError) -> PageImageReport {
        var pages: [PageImageOutcome] = []
        let hadRecord = try readEach(fileData: fileData, source: source, recordedHashes: recordedHashes) { pages.append($1) }
        return hadRecord ? .pages(pages) : .noRecord
    }

    /// The page's one image, accepted by its recorded hash and placed in the
    /// checked file; its bytes, or the reason it was not accepted.
    private static func accept(_ index: Int, fileData: Data, source: some PageImageSource, recordedHashes: [Data],
                               located: inout [Data: Range<Int>], claimed: inout [Range<Int>],
                               cursor: inout Int) -> Result<Data, PageImageRefusal> {
        func refuse(_ reason: PageImageRefusal.Reason) -> Result<Data, PageImageRefusal> {
            .failure(PageImageRefusal(reason: reason, offset: 0))
        }
        let images = source.images(onPage: index)
        guard let image = images.first else { return refuse(.noPageImage) }
        guard images.count == 1 else { return refuse(.twoPageImages) }
        guard image.isJPEG else { return refuse(.notJPEG) }
        guard index < recordedHashes.count else { return refuse(.noRecordedHash) }
        let hash = Data(SHA256.hash(data: image.bytes))
        guard hash == recordedHashes[index] else { return refuse(.hashDiffers) }
        if located[hash] != nil { return .success(image.bytes) }
        guard let range = place(image.bytes, in: fileData, from: cursor, avoiding: claimed) else {
            return refuse(.bytesNotInFile)
        }
        located[hash] = range
        claimed.append(range)
        cursor = range.upperBound
        return .success(image.bytes)
    }

    /// The first occurrence of `needle` in `file` that overlaps no claimed
    /// range, searched from `start` to the end and then from the beginning.
    static func place(_ needle: Data, in file: Data, from start: Int, avoiding claimed: [Range<Int>]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= file.count else { return nil }
        return file.withUnsafeBytes { (hay: UnsafeRawBufferPointer) -> Range<Int>? in
            needle.withUnsafeBytes { (pin: UnsafeRawBufferPointer) -> Range<Int>? in
                guard let h = hay.baseAddress, let n = pin.baseAddress else { return nil }
                func search(_ from: Int, _ to: Int) -> Range<Int>? {
                    var p = from
                    while p + pin.count <= to {
                        guard let hit = memmem(h + p, to - p, n, pin.count) else { return nil }
                        let at = h.distance(to: UnsafeRawPointer(hit))
                        let range = at..<(at + pin.count)
                        if !claimed.contains(where: { $0.overlaps(range) }) { return range }
                        p = at + 1
                    }
                    return nil
                }
                let from = min(max(0, start), hay.count)
                return search(from, hay.count) ?? search(0, min(hay.count, from + pin.count - 1))
            }
        }
    }
}
