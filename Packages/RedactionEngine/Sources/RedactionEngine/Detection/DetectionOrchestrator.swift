import Foundation

/// The namespace of the shared detection constants and of the cross-category
/// overlap resolution the search path runs (`resolveOverlaps`, in
/// `DetectionOrchestrator+OverlapResolution.swift`). It has no instance.
public enum DetectionOrchestrator: Sendable {
    /// Absorbing-state floor on the per-category
    /// prior mean (deliberate, 2026-06-10). Chosen so the weakest
    /// category's raw max (account, 0.75), composed with the worst-case
    /// floored prior, still clears every preset threshold:
    /// posterior(0.75, 0.35) ≈ 0.618 > 0.60 balanced. Public so tests
    /// and the Settings reset affordance can reference the shipped value.
    static let absorbingStateFloor = 0.35
}
