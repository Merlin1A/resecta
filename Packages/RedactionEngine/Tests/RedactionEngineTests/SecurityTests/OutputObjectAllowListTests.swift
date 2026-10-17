import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// The redacted output carries only the objects the writer is meant to emit.
// A source PDF with a marker string in its redacted body line, its
// document information dictionary, its XMP metadata, an annotation, an
// outline entry and a page label is exported in both modes through the
// production page loop (`PageRasterizer.rasterize` + `PDFStreamReconstructor`,
// via `TestPipeline.processAndExport`), and the output is read back:
//
// - the catalog, page and resources dictionaries hold only allow-listed
//   keys (Searchable adds only the text layer's own font resources);
// - none of the source's document-level carriers is present;
// - the file is a single revision (one `%%EOF`, no `/Prev`);
// - no marker appears in the raw bytes, in any decompressed stream, in
//   any string object reachable from the catalog, or in the text layer.
//
// Sources here are text PDFs. Image and encrypted sources are covered when
// their fixtures land.

@Suite("Output object allow-list", .tags(.security))
struct OutputObjectAllowListTests {

    // MARK: - The allow-lists

    static let catalogKeys: Set<String> = ["Type", "Pages"]
    static let pageKeys: Set<String> = ["Type", "Parent", "MediaBox", "Resources", "Contents"]
    static let resourceKeys: Set<String> = ["XObject", "ProcSet"]
    /// The Searchable text layer's own resources.
    static let textLayerResourceKeys: Set<String> = ["Font"]

    /// Document-level carriers a source can hold that the output never does.
    static let forbiddenCatalogKeys: Set<String> = [
        "Annots", "Metadata", "StructTreeRoot", "PageLabels", "Thumb",
        "Names", "OCProperties", "Outlines", "AA",
    ]

    static let modes: [PipelineMode] = [.secureRasterization, .searchableRedaction]

    // MARK: - The export

    struct Export {
        let source: CanarySource
        let url: URL
        let data: Data
        let document: CGPDFDocument
    }

    static func export(_ mode: PipelineMode) async throws -> Export {
        let source = TestFixtures.canarySource()
        let region = RedactionRegion(id: UUID(), normalizedRect: source.regionRect, source: .manual)
        let url = try await TestPipeline.processAndExport(
            source.data, mode: mode, regions: [0: [region]])
        let data = try Data(contentsOf: url)
        let provider = try #require(CGDataProvider(url: url as CFURL))
        let document = try #require(CGPDFDocument(provider))
        return Export(source: source, url: url, data: data, document: document)
    }

    // MARK: - Reading the output

    final class KeyCollector {
        var keys: Set<String> = []
    }

    static func keys(of dict: CGPDFDictionaryRef) -> Set<String> {
        let collector = KeyCollector()
        CGPDFDictionaryApplyBlock(dict, { key, _, info in
            guard let info else { return false }
            Unmanaged<KeyCollector>.fromOpaque(info).takeUnretainedValue()
                .keys.insert(String(cString: key))
            return true
        }, Unmanaged.passUnretained(collector).toOpaque())
        return collector.keys
    }

    /// Collects every stream (decoded) and every string reachable from a
    /// dictionary, visiting each container once.
    final class Walker {
        var streams: [Data] = []
        var strings: [String] = []
        private var seen: Set<Int> = []

        func visit(_ object: CGPDFObjectRef) {
            switch CGPDFObjectGetType(object) {
            case .dictionary:
                var dict: CGPDFDictionaryRef?
                if CGPDFObjectGetValue(object, .dictionary, &dict), let dict { visitDictionary(dict) }
            case .stream:
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
                guard seen.insert(unsafeBitCast(stream, to: Int.self)).inserted else { return }
                var format = CGPDFDataFormat.raw
                if let decoded = CGPDFStreamCopyData(stream, &format) { streams.append(decoded as Data) }
                if let dict = CGPDFStreamGetDictionary(stream) { visitDictionary(dict) }
            case .array:
                var array: CGPDFArrayRef?
                guard CGPDFObjectGetValue(object, .array, &array), let array else { return }
                guard seen.insert(unsafeBitCast(array, to: Int.self)).inserted else { return }
                for i in 0..<CGPDFArrayGetCount(array) {
                    var element: CGPDFObjectRef?
                    if CGPDFArrayGetObject(array, i, &element), let element { visit(element) }
                }
            case .string:
                var string: CGPDFStringRef?
                if CGPDFObjectGetValue(object, .string, &string), let string,
                   let text = CGPDFStringCopyTextString(string) {
                    strings.append(text as String)
                }
            default:
                break
            }
        }

        func visitDictionary(_ dict: CGPDFDictionaryRef) {
            guard seen.insert(unsafeBitCast(dict, to: Int.self)).inserted else { return }
            CGPDFDictionaryApplyBlock(dict, { _, value, info in
                guard let info else { return false }
                Unmanaged<Walker>.fromOpaque(info).takeUnretainedValue().visit(value)
                return true
            }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    static func reachable(from root: CGPDFDictionaryRef) -> (streams: [Data], strings: [String]) {
        let walker = Walker()
        walker.visitDictionary(root)
        return (walker.streams, walker.strings)
    }

    /// Every `stream … endstream` payload in the raw bytes, inflated where
    /// it is Flate-encoded (zlib header skipped), so an object the catalog
    /// does not reach is read too.
    static func inflatedRawStreams(_ data: Data) -> [Data] {
        var out: [Data] = []
        let open = Data("stream".utf8), close = Data("endstream".utf8)
        var cursor = data.startIndex
        while let start = data.range(of: open, in: cursor..<data.endIndex) {
            var body = start.upperBound
            if body < data.endIndex, data[body] == 0x0D { body += 1 }
            if body < data.endIndex, data[body] == 0x0A { body += 1 }
            guard let end = data.range(of: close, in: body..<data.endIndex) else { break }
            let payload = data[body..<end.lowerBound]
            if payload.count > 2,
               let inflated = try? (Data(payload.dropFirst(2)) as NSData).decompressed(using: .zlib) {
                out.append(inflated as Data)
            }
            cursor = end.upperBound
        }
        return out
    }

    static func contains(_ haystack: Data, _ needle: String) -> Bool {
        [String.Encoding.utf8, .utf16BigEndian, .utf16LittleEndian].contains { encoding in
            needle.data(using: encoding).map { haystack.range(of: $0) != nil } ?? false
        }
    }

    static func occurrences(of needle: String, in data: Data) -> Int {
        let bytes = Data(needle.utf8)
        var count = 0
        var cursor = data.startIndex
        while let hit = data.range(of: bytes, in: cursor..<data.endIndex) {
            count += 1
            cursor = hit.upperBound
        }
        return count
    }

    // MARK: - The tests

    @Test("Catalog, page and resources keys are allow-listed; no source carrier survives", arguments: modes)
    func dictionariesAreAllowListed(_ mode: PipelineMode) async throws {
        let export = try await Self.export(mode)
        defer { try? FileManager.default.removeItem(at: export.url) }

        let catalog = try #require(export.document.catalog)
        let catalogKeys = Self.keys(of: catalog)
        #expect(catalogKeys.isSubset(of: Self.catalogKeys),
                "catalog keys \(catalogKeys.sorted()) outside \(Self.catalogKeys.sorted())")
        #expect(catalogKeys.isDisjoint(with: Self.forbiddenCatalogKeys))

        #expect(export.document.numberOfPages == 1)
        let page = try #require(export.document.page(at: 1)?.dictionary)
        let pageKeys = Self.keys(of: page)
        #expect(pageKeys.isSubset(of: Self.pageKeys),
                "page keys \(pageKeys.sorted()) outside \(Self.pageKeys.sorted())")
        #expect(pageKeys.isDisjoint(with: Self.forbiddenCatalogKeys))

        var resources: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(page, "Resources", &resources))
        let resourceKeys = Self.keys(of: try #require(resources))
        let allowed = mode == .searchableRedaction
            ? Self.resourceKeys.union(Self.textLayerResourceKeys) : Self.resourceKeys
        #expect(resourceKeys.isSubset(of: allowed),
                "\(mode) resources keys \(resourceKeys.sorted()) outside \(allowed.sorted())")
    }

    @Test("The output is a single revision", arguments: modes)
    func singleRevision(_ mode: PipelineMode) async throws {
        let export = try await Self.export(mode)
        defer { try? FileManager.default.removeItem(at: export.url) }

        #expect(Self.occurrences(of: "%%EOF", in: export.data) == 1)
        #expect(Self.occurrences(of: "/Prev", in: export.data) == 0)
    }

    @Test("No source marker in the raw bytes, any stream, any string or the text layer", arguments: modes)
    func noSourceMarkerSurvives(_ mode: PipelineMode) async throws {
        let export = try await Self.export(mode)
        defer { try? FileManager.default.removeItem(at: export.url) }

        let catalog = try #require(export.document.catalog)
        let (streams, strings) = Self.reachable(from: catalog)
        let rawStreams = Self.inflatedRawStreams(export.data)
        #expect(!streams.isEmpty, "the page's content and image streams are reachable")
        let text = PDFDocument(url: export.url)?.string ?? ""

        for (place, marker) in export.source.canaries.sorted(by: { $0.key < $1.key }) {
            #expect(!Self.contains(export.data, marker), "\(place) marker in the raw bytes (\(mode))")
            #expect(!streams.contains { Self.contains($0, marker) },
                    "\(place) marker in a reachable stream (\(mode))")
            #expect(!rawStreams.contains { Self.contains($0, marker) },
                    "\(place) marker in an inflated stream (\(mode))")
            #expect(!strings.contains { $0.contains(marker) },
                    "\(place) marker in a string object (\(mode))")
            #expect(!text.contains(marker), "\(place) marker in the text layer (\(mode))")
        }
    }

    /// The control for the text-layer read-back: in Searchable mode the line
    /// outside every region is still read, so the absence above is the
    /// region's work and not an empty read.
    @Test("Searchable output keeps the body line outside every region")
    func searchableKeepsTheUnredactedLine() async throws {
        let export = try await Self.export(.searchableRedaction)
        defer { try? FileManager.default.removeItem(at: export.url) }

        let text = PDFDocument(url: export.url)?.string ?? ""
        #expect(text.contains(export.source.keptLine),
                "the line outside every region is in the Searchable text layer")
    }
}
