import Testing
import RedactionCore

@Suite struct PageRect64Tests {
    @Test func rectanglesOneSixtyFourthApartAreNotEqual() {
        let a = PageRect64(minX: 640, minY: 1_280, maxX: 6_400, maxY: 2_048)
        #expect(a == PageRect64(minX: 640, minY: 1_280, maxX: 6_400, maxY: 2_048))
        #expect(a != PageRect64(minX: 641, minY: 1_280, maxX: 6_400, maxY: 2_048))
        #expect(a != PageRect64(minX: 640, minY: 1_281, maxX: 6_400, maxY: 2_048))
        #expect(a != PageRect64(minX: 640, minY: 1_280, maxX: 6_401, maxY: 2_048))
        #expect(a != PageRect64(minX: 640, minY: 1_280, maxX: 6_400, maxY: 2_049))
        #expect(Set([a, a]).count == 1)
    }

    @Test func sizesAreTheDifferencesOfTheEdges() {
        let r = PageRect64(minX: -64, minY: 100, maxX: 192, maxY: 228)
        #expect(r.width == 256)
        #expect(r.height == 128)
    }

    @Test func aRectangleWithNoAreaIsEmpty() {
        #expect(PageRect64(minX: 0, minY: 0, maxX: 0, maxY: 64).isEmpty)
        #expect(PageRect64(minX: 0, minY: 0, maxX: 64, maxY: 0).isEmpty)
        #expect(PageRect64(minX: 64, minY: 0, maxX: 0, maxY: 64).isEmpty)
        #expect(!PageRect64(minX: 0, minY: 0, maxX: 1, maxY: 1).isEmpty)
    }

    @Test func anEdgeMayLieOffThePage() {
        let r = PageRect64(minX: -128, minY: -64, maxX: 50_752, maxY: 50_689)
        #expect(r.minX == -128 && r.minY == -64)
        #expect(!r.isEmpty)
    }
}
