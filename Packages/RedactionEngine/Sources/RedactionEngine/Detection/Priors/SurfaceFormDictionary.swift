import Foundation

// Plan §2 / A7 — exact-match surface-form propagation. After the user
// accepts or rejects a detection, the surface string ("123-45-6789",
// "Dr. Jane Smith") is recorded here so later pages short-circuit to the
// same decision without re-scoring.
//
// Keys normalized via TextNormalizer.normalize (NFKC + ligature expansion)
// then lowercased with whitespace collapsed. Sendable value type; merged
// commutatively at yield alongside PerCategoryPriors.
//
// Bounded-growth cap at 10,000 entries via
// insertion-LRU. The cap is a hardcoded compile-time constant; no runtime
// configuration surface (V1.1+ may revisit).

public struct SurfaceFormDictionary: Sendable, Equatable {

    /// Maximum number of entries before insertion-LRU eviction kicks in.
    /// `internal` so tests may assert against it; not part of the public API.
    /// Spec §7.7 F-11: hardcoded for V1; runtime configuration deferred.
    internal static let capacity = 10_000

    private var map: [String: Decision]

    /// Normalized keys in write order (oldest first, most-recent last). Kept
    /// in lockstep with `map.keys`. Bookkeeping for the LRU cap only — does
    /// NOT participate in `Equatable` (see manual `==` below). Two dicts with
    /// identical content but different write sequences must remain `==` to
    /// preserve V1 semantics for any caller doing dictionary equality.
    private var order: [String]

    public init() {
        self.map = [:]
        self.order = []
    }

    public init(_ initial: [String: Decision]) {
        let normalizedPairs = initial.map { (Self.normalize($0.key), $0.value) }
        var newMap = Dictionary(uniqueKeysWithValues: normalizedPairs)
        var newOrder = normalizedPairs.map { $0.0 }
        while newMap.count > Self.capacity, let oldest = newOrder.first {
            newMap.removeValue(forKey: oldest)
            newOrder.removeFirst()
        }
        self.map = newMap
        self.order = newOrder
    }

    public var isEmpty: Bool { map.isEmpty }
    public var count: Int { map.count }

    public func lookup(_ surface: String) -> Decision? {
        map[Self.normalize(surface)]
    }

    public func recording(_ surface: String, decision: Decision) -> SurfaceFormDictionary {
        let normalized = Self.normalize(surface)
        var newMap = map
        var newOrder = order
        if newMap[normalized] != nil {
            newOrder.removeAll { $0 == normalized }
        }
        newMap[normalized] = decision
        newOrder.append(normalized)
        while newMap.count > Self.capacity, let oldest = newOrder.first {
            newMap.removeValue(forKey: oldest)
            newOrder.removeFirst()
        }
        var result = SurfaceFormDictionary()
        result.map = newMap
        result.order = newOrder
        #if DEBUG
        assert(result.map.count <= Self.capacity)
        assert(result.map.count == result.order.count)
        #endif
        return result
    }

    /// Commutative merge. Conflicts (same surface, different decision) favor
    /// the **newer** argument (`other` wins). Callers on MainActor fold
    /// per-page deltas via `existing.merged(pageResult.surfaceDelta)`.
    ///
    /// Cap policy: if the merged result would exceed `capacity`,
    /// evict from the oldest-write end. Tie-break for ordering in the merged
    /// result: keys present only in `self` keep `self`'s order; all keys
    /// from `other` (whether new or conflicting) appear after, in `other`'s
    /// relative order. This means `other`-side writes survive eviction over
    /// older `self`-side writes at conflict, matching the existing
    /// "other wins" content semantics.
    public func merged(_ other: SurfaceFormDictionary) -> SurfaceFormDictionary {
        var newMap = map
        let otherKeys = Set(other.order)
        var newOrder = order.filter { !otherKeys.contains($0) }
        for (key, value) in other.map {
            newMap[key] = value
        }
        newOrder.append(contentsOf: other.order)
        let excess = newMap.count - Self.capacity
        if excess > 0 {
            for i in 0..<excess {
                newMap.removeValue(forKey: newOrder[i])
            }
            newOrder.removeFirst(excess)
        }
        var copy = SurfaceFormDictionary()
        copy.map = newMap
        copy.order = newOrder
        #if DEBUG
        assert(copy.map.count <= Self.capacity)
        assert(copy.map.count == copy.order.count)
        #endif
        return copy
    }

    /// Manual implementation preserves V1 dictionary-equality semantics
    /// across the LRU-bookkeeping representation change. The auto-synthesized
    /// `Equatable` would compare both `map` and `order`; that would make two
    /// dicts with the same final content but different write sequences
    /// compare unequal — an observable change for any caller doing
    /// `existing == new`. Equality remains "same key/value pairs."
    public static func == (lhs: SurfaceFormDictionary, rhs: SurfaceFormDictionary) -> Bool {
        lhs.map == rhs.map
    }

    /// NFKC + ligature expansion, lowercased, internal whitespace collapsed
    /// to single spaces, trimmed. Mirror of the normalization detectors
    /// apply to input text — ensures `"Dr.  Jane   Smith"` and
    /// `"dr. jane smith"` hit the same entry.
    private static func normalize(_ surface: String) -> String {
        let base = TextNormalizer.normalize(surface).lowercased()
        let components = base.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return components.joined(separator: " ")
    }
}
