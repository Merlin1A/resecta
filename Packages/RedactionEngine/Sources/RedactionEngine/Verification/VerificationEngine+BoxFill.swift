import Foundation
import PDFKit

extension VerificationEngine {
    /// Box Fill: every box of the run's record judged on the stored page
    /// picture, read as the row. No record is read by the row too: Skipped.
    /// An output whose bytes cannot be loaded leaves every page of the record
    /// unread.
    func runBoxFill(_ doc: PDFDocument, record: RunRecord?) throws -> BoxFillRow.Reading {
        try Task.checkCancellation()
        guard let record else { return BoxFillRow.reading(report: .pages([]), record: nil) }
        guard let (data, _) = loadPDFData(doc), let source = SystemPageImageSource(fileData: data) else {
            return BoxFillRow.reading(report: .pages([]), record: record)
        }
        let report = try ExactFillCheck.run(fileData: data, source: source, input: BoxCheckInput(record: record))
        return BoxFillRow.reading(report: report, record: record)
    }
}
