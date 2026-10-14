import Foundation
import CoreTransferable
import UniformTypeIdentifiers
import RedactionEngine

/// What the drop door hands the workspace: the dropped file's bytes, or the
/// refusal met before any byte was read. The system copies a dropped file
/// to a location it may remove once the importing closure returns, so the
/// closure reads it there and then — by its size on disk first, then the
/// bytes, mapped when the system allows.
struct DroppedDocument: Transferable {
    enum Payload: Sendable {
        case bytes(Data)
        case refused(PipelineError.ImportFailure)
    }

    let payload: Payload

    /// Read the received file through the import's file read. A refusal is
    /// carried, not thrown, so the drop surfaces it instead of failing
    /// silently.
    static func payload(reading url: URL) -> Payload {
        do {
            return .bytes(try ImportService.readPayload(from: url))
        } catch let error as PipelineError {
            if case .importError(let failure) = error {
                return .refused(failure)
            }
            return .refused(.corrupt)
        } catch {
            return .refused(.corrupt)
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { received in
            DroppedDocument(payload: payload(reading: received.file))
        }
    }
}
