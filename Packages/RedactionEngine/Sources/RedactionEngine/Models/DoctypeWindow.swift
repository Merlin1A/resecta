import Foundation

// Plan §2 / G5 — doctype context carried into per-page detection.
// Within ±3 pages of a type boundary (e.g., court→medical transition in a
// multi-doc packet), `secondary` carries the neighbouring type so detectors
// can widen gating at the seam. Outside boundary windows, `secondary` is nil.

public struct DoctypeWindow: Sendable, Equatable {
    public let primary: DoctypeClass
    public let secondary: DoctypeClass?

    public init(primary: DoctypeClass, secondary: DoctypeClass? = nil) {
        self.primary = primary
        self.secondary = secondary
    }
}
