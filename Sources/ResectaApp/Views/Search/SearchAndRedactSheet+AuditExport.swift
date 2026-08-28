import SwiftUI
import RedactionEngine

// Audit export — `exportAudit(includeSensitive:)` lifted from
// `SearchAndRedactSheet.swift` (split target
// "<500 LOC sheet"). Pure structural lift; no behavior change. Called
// from the main sheet's export confirmation dialog.
//
// The call surface extends with `schema:` so the
// confirmation dialog can thread the chosen `AuditSchemaVersion`
// through to `ExportMetadata.schemaVersion` at construction time.
// Engine reality: `ExportMetadata.init(schemaVersion: 4)` is the
// default — v4 emits `ruleVersion` +
// `gazetteerManifestVersion` columns. V1.0 ships v4 only; a v3
// column-subset emit path on `MatchAuditExporter` is deferred scope.

/// Audit-export schema selector for the confirmation dialog.
/// v4 is the engine's current default (ships `ruleVersion` +
/// `gazetteerManifestVersion` columns) and the only schema V1.0
/// exports. The deferred v3 column-subset path is not yet built.
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

    // MARK: - Audit Export

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
            documentName: "document",  // filenames kept generic
            totalMatches: records.count,
            appliedMatches: records.filter(\.wasApplied).count
        )
        await MatchExportService.share(
            records: records,
            metadata: metadata,
            includeSensitive: includeSensitive,
            documentName: "document",
            // Artifacts land in the hardened
            // per-session directory, not the bare temp root.
            tempDirectory: pipelineCoordinator.tempExportDirectory,
            // Share presentation is withheld while shielded.
            captureMonitor: captureMonitor,
            toastManager: toastManager,
            from: presenter
        )
    }
}
