import Testing
import Foundation
@testable import RedactionEngine

// The engine's own import-refusal copy. The app shows its own recovery
// text for a refused format; this string is what a package consumer reads.

@Suite("PipelineError copy")
struct PipelineErrorCopyTests {

    @Test("The unsupported-format description names PDF and the three image formats")
    func unsupportedFormatNamesTheFormats() {
        let text = PipelineError.importError(.unsupportedFormat).errorDescription ?? ""
        #expect(text.contains("PDF"), "got \(text)")
        for format in ["JPEG", "PNG", "HEIC"] {
            #expect(text.contains(format), "names \(format); got \(text)")
        }
        #expect(!text.contains("image files"), "the generic phrase gave way to the formats; got \(text)")
    }
}
