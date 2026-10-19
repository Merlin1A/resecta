import Foundation
import PDFKit
import RedactionEngine

/// The per-consumer copy the search and the live preview read, built from
/// the open document's bytes. A source that was unlocked with a password
/// re-emits its bytes still encrypted for the 40- and 128-bit revisions, so
/// the copy opens locked and would read no text; it is unlocked here with
/// the session's password. A copy that stays locked, or bytes PDFKit cannot
/// emit, come back as nil: the callers' existing nil path shows the
/// "could not prepare" toast — a locked copy is an error, never zero
/// matches.
nonisolated enum SearchCopy {
    static func make(
        of source: SendablePDFDocument,
        unlockingWith holder: DocumentPasswordHolder
    ) -> SendablePDFDocument? {
        guard let copy = DocumentState.makeSearchCopy(of: source) else { return nil }
        let document = copy.document
        if document.isLocked {
            _ = holder.withPassword { document.unlock(withPassword: $0) }
        }
        guard !document.isLocked else { return nil }
        return copy
    }
}
