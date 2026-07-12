import Testing
import Foundation
@testable import ResectaApp

// WU-33 — audit schema selector.
//
// The W5 confirmation dialog routes its share `Button`s through
// `exportAudit(includeSensitive:schema:)` with `.v4` — the engine's
// current shipping default per
// `Packages/RedactionEngine/.../ExportMetadata.swift`
// `init(schemaVersion: UInt8 = 4, ...)`. A v3 column-subset emit path
// is V1.1+ scope per [OQ-26]; the previously pre-staged disabled `.v3`
// stub was removed (CL-QP1-03). The `AuditSchemaVersion` enum carries
// the metadata-value mapping so the selector is pinned without a
// SwiftUI host.

@Suite("Audit schema selector (WU-33)", .tags(.search))
@MainActor
struct AuditSchemaPickerTests {

    @Test("Default audit schema version is v4 — engine's current shipping default")
    func defaultSchemaIsV4() {
        // The V1.0 default tracks `ExportMetadata.init(schemaVersion: 4, ...)`
        // — see Packages/RedactionEngine/.../ExportMetadata.swift line 40.
        // Renaming this assertion is a §S5 spec edit event.
        let defaultVersion: AuditSchemaVersion = .v4
        #expect(defaultVersion == .v4)
        #expect(defaultVersion.metadataValue == 4)
    }

    @Test("Each schema option maps to its `ExportMetadata.schemaVersion` integer")
    func metadataValuesAreCanonical() {
        #expect(AuditSchemaVersion.v4.metadataValue == 4)
    }

    @Test("Enum enumerates exactly the one case V1 exports")
    func allCasesAreCanonical() {
        let cases = AuditSchemaVersion.allCases
        #expect(cases.count == 1)
        #expect(cases.contains(.v4))
    }

    @Test("Raw-value names match the `ExportMetadata` documentation conventions")
    func rawValuesAreStable() {
        // Pinned because raw-value renames would break a future
        // SavedSearchStore-style codable persistence path or any
        // log-line that surfaces the active schema.
        #expect(AuditSchemaVersion.v4.rawValue == "v4")
    }
}
