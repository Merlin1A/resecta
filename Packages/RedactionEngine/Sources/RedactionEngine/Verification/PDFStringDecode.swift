import CoreGraphics
import Foundation

/// The decode of a PDF string object, as the metadata check and the
/// content-stream check read it. Its default is the real call
/// (`CGPDFStringCopyTextString`). A value it returns nothing for is a value
/// the check could not read. No hand-built file makes the system's decoder
/// return nothing, so a test binds a decode that does. Task-local; read on
/// the checking task.
enum PDFStringDecode {
    @TaskLocal static var decode: @Sendable (CGPDFStringRef) -> String? = { CGPDFStringCopyTextString($0) as String? }
}
