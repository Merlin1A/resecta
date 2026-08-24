import Testing
import Foundation
@testable import ResectaApp

// UXC-18 — effective-touch-target floor program.
//
// Pins two things cheaply, without a simulator host:
//   1. The `ResectaTokens.TouchTarget.minimum` value itself.
//   2. Source-contains pins (mirrors HonestySurfacesTests'
//      `loadRepoFile` idiom) proving each floored site actually
//      REFERENCES the shared token — not a bare `46` literal that
//      could drift independently of the catalog value — plus the new
//      stable identifiers this program added, and the load-bearing
//      `.buttonStyle(.plain)` on the sheet's fixed-chrome buttons
//      (18-SCROLL-ARCH §10: default-styled buttons there are a proven
//      cooperative-scroll-arbitration poison — a future contributor
//      "fixing" the frame must not be able to drop `.plain`).
//
// The visual/hit-test verification these source pins can't reach
// (actual on-screen frame size, the accessibility-merged FindingRow
// selection circle, the resize handles) is a simulator/XCUITest or
// coordinate-probe pass — see ResizeHandleHitTestTests for the
// resize-handle geometry's pure-function coverage instead.

@Suite("Touch-target floor (UXC-18)", .tags(.display))
struct TouchTargetFloorTests {

    @Test("ResectaTokens.TouchTarget.minimum is the HIG EFFECTIVE floor (46pt layout / RB-54)")
    func touchTargetMinimumIsFortySix() {
        // RB-54: 46, not 44 — the medium-detent inset sheet renders at
        // ~0.96 scale on iOS 26, so a 46pt layout frame is what yields
        // >=44pt EFFECTIVE inside the sheet (measured 2026-08-22).
        #expect(ResectaTokens.TouchTarget.minimum == 46)
    }

    @Test("TouchTarget.pencil is untouched by the UXC-18 addition")
    func pencilConstantUnchanged() {
        #expect(ResectaTokens.TouchTarget.pencil == 22)
    }

    // MARK: - Source pins: every floored site references the token

    @Test("Every UXC-18 site references ResectaTokens.TouchTarget.minimum, not a bare 46")
    func everySiteReferencesTheSharedToken() throws {
        let sites = [
            "Sources/ResectaApp/Views/Search/FindingRow.swift",
            "Sources/ResectaApp/Views/FilterChip.swift",
            "Sources/ResectaApp/Views/PageNavigationBar.swift",
            "Sources/ResectaApp/Views/SearchResultRow.swift",
            "Sources/ResectaApp/Views/Search/ScanReviewSection.swift",
            "Sources/ResectaApp/Views/Search/SearchResultsSection.swift",
            "Sources/ResectaApp/Views/Search/SearchToolbarSection.swift",
            "Sources/ResectaApp/Views/SearchAndRedactSheet.swift",
            "Sources/ResectaApp/Views/Search/SearchSheetHeaderSection.swift",
            "Sources/ResectaApp/Views/Search/SearchFooterSection.swift",
            "Sources/ResectaApp/Overlay/RedactionOverlayView.swift",
        ]
        for path in sites {
            let source = try loadRepoFile(path)
            #expect(
                source.contains("ResectaTokens.TouchTarget.minimum"),
                "\(path) must reference ResectaTokens.TouchTarget.minimum"
            )
        }
    }

    // MARK: - New identifiers (UXC-18, lead ruling #9)

    @Test("The new stable identifiers this program added are present in source")
    func newIdentifiersArePresent() throws {
        let expectations: [(path: String, identifier: String)] = [
            ("Sources/ResectaApp/Views/Search/ScanReviewSection.swift", "detectorEvaluationButton"),
            ("Sources/ResectaApp/Views/SearchResultRow.swift", "rationaleDisclosureButton"),
            ("Sources/ResectaApp/Views/Search/SearchToolbarSection.swift", "rescanButton"),
            ("Sources/ResectaApp/Views/SearchAndRedactSheet.swift", "rescanButton"),
            ("Sources/ResectaApp/Views/SearchAndRedactSheet.swift", "savedSearchesBookmark"),
            ("Sources/ResectaApp/Views/SearchAndRedactSheet.swift", "resultNavPrevious"),
            ("Sources/ResectaApp/Views/SearchAndRedactSheet.swift", "resultNavNext"),
        ]
        for expectation in expectations {
            let source = try loadRepoFile(expectation.path)
            #expect(
                source.contains(
                    "accessibilityIdentifier(\"\(expectation.identifier)\")"
                ),
                "\(expectation.path) must carry .accessibilityIdentifier(\"\(expectation.identifier)\")"
            )
        }
    }

    @Test("Existing identifiers this program did NOT touch stay byte-identical")
    func preExistingIdentifiersUnchanged() throws {
        // STRING-FREE constraint guard: the page-bar chevrons and the
        // sheet header/footer already had identifiers before UXC-18;
        // this program only added frame/contentShape around them.
        let expectations: [(path: String, identifier: String)] = [
            ("Sources/ResectaApp/Views/PageNavigationBar.swift", "pageNavPrevious"),
            ("Sources/ResectaApp/Views/PageNavigationBar.swift", "pageNavNext"),
            ("Sources/ResectaApp/Views/Search/SearchSheetHeaderSection.swift", "searchDismissButton"),
            ("Sources/ResectaApp/Views/Search/SearchSheetHeaderSection.swift", "searchApplyButton"),
            ("Sources/ResectaApp/Views/Search/SearchFooterSection.swift", "footerSelectAllButton"),
        ]
        for expectation in expectations {
            let source = try loadRepoFile(expectation.path)
            #expect(
                source.contains(
                    "accessibilityIdentifier(\"\(expectation.identifier)\")"
                ),
                "\(expectation.path) must still carry .accessibilityIdentifier(\"\(expectation.identifier)\")"
            )
        }
    }

    // MARK: - Arbitration-poison guard (18-SCROLL-ARCH §10)

    @Test("Dismiss and Apply stay .buttonStyle(.plain) after the UXC-18 frame restructuring")
    func sheetHeaderButtonsStayPlainStyled() throws {
        let source = try loadRepoFile(
            "Sources/ResectaApp/Views/Search/SearchSheetHeaderSection.swift"
        )
        let plainCount = source.components(separatedBy: ".buttonStyle(.plain)").count - 1
        #expect(
            plainCount >= 2,
            "Dismiss and Apply must both keep .buttonStyle(.plain) — default-styled buttons in the sheet's fixed chrome are a proven cooperative-scroll-arbitration poison (18-SCROLL-ARCH §10)."
        )
    }

    @Test("Select All keeps the ruled prominent/quiet asymmetry (REV-01 custom capsule vs untouched quiet branch)")
    func footerSelectAllStaysOnItsExistingStyles() throws {
        // REV-01 (packet §7.2 item 5): the prominent branch draws a
        // compact BrandTeal capsule itself — the system
        // `.borderedProminent` wash rendered the floored label as a
        // ≥46pt pill — with states on `CapsulePressButtonStyle`; the
        // Deselect branch keeps the quiet default styling it always
        // had. Both labels survive byte-identical.
        let source = try loadRepoFile(
            "Sources/ResectaApp/Views/Search/SearchFooterSection.swift"
        )
        #expect(source.contains("ResectaTokens.BrandTeal.tint, in: Capsule()"),
                "the prominent Select All must draw the ruled BrandTeal capsule")
        #expect(source.contains(".buttonStyle(.capsulePress)"),
                "the prominent Select All must carry the custom pressed state")
        #expect(!source.contains(".buttonStyle(.borderedProminent)"),
                "the system prominent wash must stay retired on this surface (REV-01)")
        #expect(source.contains("\"Select All\""))
        #expect(source.contains("\"Deselect All\""))
    }

    // MARK: - Helper

    private func loadRepoFile(
        _ relativePath: String, from file: StaticString = #filePath
    ) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }
}
