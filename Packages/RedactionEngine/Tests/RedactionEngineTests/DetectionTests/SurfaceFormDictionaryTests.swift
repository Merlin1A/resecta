import Testing
@testable import RedactionEngine

// Plan Phase 3 / §A7 — SurfaceFormDictionary normalization.

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
