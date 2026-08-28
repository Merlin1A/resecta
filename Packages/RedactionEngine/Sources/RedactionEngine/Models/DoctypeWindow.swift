import Foundation

// G5 — doctype context carried into per-page detection.
// Multi-doc-packet boundary widening (a neighbouring-type field alongside
// `primary`) was scaffolded but never wired up: every production call site
// only ever threads the primary doctype across pages.

public struct DoctypeWindow: Sendable, Equatable {
    public let primary: DoctypeClass

    public init(primary: DoctypeClass) {
        self.primary = primary
    }
}
