import SwiftUI
import RedactionEngine

// Audit export — `exportAudit(includeSensitive:)` lifted from
// `SearchAndRedactSheet.swift` (split target
// "<500 LOC sheet"). Pure structural lift; no behavior change. Called
// from the main sheet's export confirmation dialog.
//
// WU-33 (session-12) extends the call surface with `schema:` so the
// confirmation dialog can thread the chosen `AuditSchemaVersion`
// through to `ExportMetadata.schemaVersion` at construction time.
// Engine reality: `ExportMetadata.init(schemaVersion: 4)` is the
// default since W-I2 — v4 emits `ruleVersion` +
// `gazetteerManifestVersion` columns. V1.0 ships v4 only; a v3
// column-subset emit path on `MatchAuditExporter` is V1.1+ scope
// per [OQ-26].

/// Audit-export schema selector for the W5 confirmation dialog.
/// v4 is the engine's current default (ships `ruleVersion` +
/// `gazetteerManifestVersion` columns) and the only schema V1.0
/// exports. See [OQ-26] for the deferred v3 column-subset path.
enum AuditSchemaVersion: String, Sendable, Equatable, CaseIterable {
    case v4

    /// The `ExportMetadata.schemaVersion` value this option
    /// resolves to at metadata-build time.
    var metadataValue: UInt8 {
        switch self {
        case .v4: return 4
        }
    }
}

extension SearchAndRedactSheet {

    // MARK: - W5 Audit Export

    func exportAudit(includeSensitive: Bool, schema: AuditSchemaVersion = .v4) async {
        guard let presenter = MatchExportService.topViewController() else {
            toastManager.enqueue(
                "Unable to present the share sheet right now.",
                severity: .warning
            )
            return
        }
        let records = MatchExportService.makeRecords(
            liveResults: searchState.results,
            applied: redactionState.appliedMatchAuditSnapshots
        )
        guard !records.isEmpty else {
            toastManager.enqueue("No matches to export.", severity: .info)
            return
        }
        let metadata = ExportMetadata(
            schemaVersion: schema.metadataValue,
            appVersion: Bundle.main.appVersion,
            presetName: "Default",
            perCategoryOverrides: [:],
            documentName: "document",  // filenames kept generic per UI_UX §5.4
            totalMatches: records.count,
            appliedMatches: records.filter(\.wasApplied).count
        )
        await MatchExportService.share(
            records: records,
            metadata: metadata,
            includeSensitive: includeSensitive,
            documentName: "document",
            // S6 audit-leak fix: artifacts land in the SEC-2 hardened
            // per-session directory, not the bare temp root.
            tempDirectory: pipelineCoordinator.tempExportDirectory,
            // S6 / C10: share presentation is withheld while shielded.
            captureMonitor: captureMonitor,
            toastManager: toastManager,
            from: presenter
        )
    }
}
