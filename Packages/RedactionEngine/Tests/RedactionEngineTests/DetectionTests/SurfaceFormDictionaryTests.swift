import Testing
@testable import RedactionEngine

// Plan Phase 3 / §A7 — SurfaceFormDictionary normalization + merge.

@Suite("SurfaceFormDictionary")
struct SurfaceFormDictionaryTests {

    @Test("Empty dictionary returns nil")
    func emptyLookup() {
        let dict = SurfaceFormDictionary()
        #expect(dict.lookup("anything") == nil)
    }

    @Test("Recording persists a lookup")
    func recordAndLookup() {
        let dict = SurfaceFormDictionary()
            .recording("Dr. Jane Smith", decision: .accepted)
        #expect(dict.lookup("Dr. Jane Smith") == .accepted)
    }

    @Test("Normalization: whitespace + case")
    func normalization() {
        let dict = SurfaceFormDictionary()
            .recording("Dr.  Jane   Smith", decision: .accepted)
        #expect(dict.lookup("dr. jane smith") == .accepted)
        #expect(dict.lookup("Dr. Jane   Smith") == .accepted)
    }

    @Test("Merged dictionary unions both sets")
    func merge() {
        let a = SurfaceFormDictionary()
            .recording("alpha", decision: .accepted)
        let b = SurfaceFormDictionary()
            .recording("beta", decision: .rejected)
        let merged = a.merged(b)
        #expect(merged.lookup("alpha") == .accepted)
        #expect(merged.lookup("beta") == .rejected)
    }

    @Test("Merge conflict resolves to 'other' (newer)")
    func mergeConflict() {
        let original = SurfaceFormDictionary()
            .recording("foo", decision: .accepted)
        let newer = SurfaceFormDictionary()
            .recording("foo", decision: .rejected)
        #expect(original.merged(newer).lookup("foo") == .rejected)
    }

    // D-29: bounded-growth cap regression tests.

    @Test("Recording exactly capacity entries keeps all")
    func recordingExactlyCapacityKeepsAll() {
        var dict = SurfaceFormDictionary()
        for i in 0..<SurfaceFormDictionary.capacity {
            dict = dict.recording("surface\(i)", decision: .accepted)
        }
        #expect(dict.count == SurfaceFormDictionary.capacity)
        #expect(dict.lookup("surface0") == .accepted)
        #expect(dict.lookup("surface\(SurfaceFormDictionary.capacity - 1)") == .accepted)
    }

    @Test("Recording beyond capacity evicts oldest")
    func recordingBeyondCapacityEvictsOldest() {
        var dict = SurfaceFormDictionary()
        for i in 0..<(SurfaceFormDictionary.capacity + 1) {
            dict = dict.recording("surface\(i)", decision: .accepted)
        }
        #expect(dict.count == SurfaceFormDictionary.capacity)
        #expect(dict.lookup("surface0") == nil)
        #expect(dict.lookup("surface1") == .accepted)
        #expect(dict.lookup("surface\(SurfaceFormDictionary.capacity)") == .accepted)
    }

    @Test("Re-recording the same key does not evict")
    func recordingSameKeyTwiceDoesNotEvict() {
        let dict = SurfaceFormDictionary()
            .recording("foo", decision: .accepted)
            .recording("foo", decision: .rejected)
        #expect(dict.count == 1)
        #expect(dict.lookup("foo") == .rejected)
    }

    @Test("Merging two full dictionaries stays at capacity")
    func mergeOfTwoFullDictsStaysAtCapacity() {
        // Bulk init avoids the O(n²) wall-clock cost of building two full
        // dicts via sequential `recording`. The merge tie-break (other-wins
        // on order) is still exercised: all of `right`'s keys land after
        // all of `left`'s in the merged order list, regardless of how each
        // side was built. Eviction therefore drops `left*` keys first.
        let leftPairs = (0..<SurfaceFormDictionary.capacity).map { ("left\($0)", Decision.accepted) }
        let rightPairs = (0..<SurfaceFormDictionary.capacity).map { ("right\($0)", Decision.rejected) }
        let left = SurfaceFormDictionary(Dictionary(uniqueKeysWithValues: leftPairs))
        let right = SurfaceFormDictionary(Dictionary(uniqueKeysWithValues: rightPairs))
        let merged = left.merged(right)
        #expect(merged.count == SurfaceFormDictionary.capacity)
        #expect(merged.lookup("right0") == .rejected)
        #expect(merged.lookup("right\(SurfaceFormDictionary.capacity - 1)") == .rejected)
        #expect(merged.lookup("left0") == nil)
    }

    @Test("Equality compares only contents, ignoring write order")
    func equalityIgnoresWriteOrder() {
        let forward = SurfaceFormDictionary()
            .recording("alpha", decision: .accepted)
            .recording("beta", decision: .rejected)
        let reverse = SurfaceFormDictionary()
            .recording("beta", decision: .rejected)
            .recording("alpha", decision: .accepted)
        #expect(forward == reverse)
    }
}
