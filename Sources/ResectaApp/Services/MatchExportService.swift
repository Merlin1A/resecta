import Foundation
import UIKit
import RedactionEngine

// W5 — build audit records from live SearchResult + applied snapshots,
// write CSV + JSON to the temp directory, and present the iOS share
// sheet. Temp files are cleaned up in the completion handler regardless
// of whether the share sheet completes or is cancelled. No scratch file
// persists between sessions.

enum MatchExportService {

    // MARK: - Record assembly

    /// Join live search results with document-wide applied snapshots.
    /// - Each live result produces one record (with `isSelected` /
    ///   `wasApplied` flags derived from the join).
    /// - Applied snapshots whose `resultID` is not in `liveResults` (e.g.,
    ///   user closed and reopened the search sheet, losing live results)
    ///   still produce a record — the audit must cover every applied
    ///   redaction, even the ones no longer tracked live.
    static func makeRecords(
        liveResults: [SearchResult],
        applied: [MatchAuditSnapshot]
    ) -> [MatchAuditRecord] {
        let appliedByResultID = Dictionary(
            uniqueKeysWithValues: applied.map { ($0.resultID, $0) }
        )
        var out: [MatchAuditRecord] = []
        out.reserveCapacity(liveResults.count + applied.count)
        var seen: Set<UUID> = []

        for result in liveResults {
            let snapshot = appliedByResultID[result.id]
            out.append(recordFromLive(result, wasApplied: snapshot != nil))
            seen.insert(result.id)
        }

        for snapshot in applied where !seen.contains(snapshot.resultID) {
            out.append(recordFromSnapshot(snapshot))
        }

        return out
    }

    private static func recordFromLive(
        _ result: SearchResult,
        wasApplied: Bool
    ) -> MatchAuditRecord {
        MatchAuditRecord(
            id: result.id,
            pageIndex: result.pageIndex,
            matchedText: result.matchedText,
            source: MatchAuditExporter.sourceDescription(result.source),
            piiCategory: result.piiCategory?.rawValue,
            piiConfidence: result.piiConfidence,
            term: result.term,
            ruleID: result.rationale?.ruleID,
            finalScore: result.rationale?.finalScore,
            appliedThreshold: result.rationale?.appliedThreshold,
            rationaleSummary: MatchAuditExporter.rationaleSummary(result.rationale),
            isSelected: result.isSelected,
            wasApplied: wasApplied,
            foiaExemption: nil,
            foiaCitation: nil,
            foiaNote: nil,
            ruleVersion: ruleVersion(for: result.rationale?.ruleID),
            gazetteerManifestVersion: ExportMetadataLoader.shared.manifestVersion
        )
    }

    private static func recordFromSnapshot(
        _ s: MatchAuditSnapshot
    ) -> MatchAuditRecord {
        // Scan-origin snapshots leave the search-only fields nil (no
        // query term, no per-word OCR source confidence, sometimes no
        // text). The export row renders them as empty columns — the
        // artifact never invents values the origin did not record.
        // Search-origin snapshots populate all three, so the emitted v4
        // rows for them are unchanged. (Export surfaces stay compiled
        // off for 1.0 either way.)
        MatchAuditRecord(
            id: s.resultID,
            pageIndex: s.pageIndex,
            matchedText: s.matchedText ?? "",
            source: s.source.map(MatchAuditExporter.sourceDescription) ?? "",
            piiCategory: s.piiCategory?.rawValue,
            piiConfidence: s.piiConfidence,
            term: s.term ?? "",
            ruleID: s.rationale?.ruleID,
            finalScore: s.rationale?.finalScore,
            appliedThreshold: s.rationale?.appliedThreshold,
            rationaleSummary: MatchAuditExporter.rationaleSummary(s.rationale),
            isSelected: false,
            wasApplied: true,
            foiaExemption: nil,
            foiaCitation: nil,
            foiaNote: nil,
            ruleVersion: ruleVersion(for: s.rationale?.ruleID),
            gazetteerManifestVersion: ExportMetadataLoader.shared.manifestVersion
        )
    }

    /// W-I2 — translate engine ruleID through the A22 alias map and return
    /// the catalog `version` string. Returns nil when the engine emits a
    /// ruleID without a catalog mapping (synthetic `user.alwaysFlag`,
    /// fallback `pii.other`) or when `RuleCatalog` failed to load.
    private static func ruleVersion(for engineRuleID: String?) -> String? {
        guard let engineRuleID else { return nil }
        return RuleCatalog.shared?.entry(forEngineRuleID: engineRuleID)?.version
    }

    // MARK: - Share

    /// Pkg C / ERR-01 + ERR-02: copy surfaced when the triage CSV / JSON
    /// pair fails to write — or when the JSON encoder itself throws (Pkg C
    /// flipped `MatchAuditExporter.json` to a throwing signature). Mechanism
    /// description per ARCH §1.3. Pinned by `MatchExportServiceFailureTests`.
    static let triageWriteFailureToastMessage = "Could not save the match audit log."

    /// Pkg C / ERR-04: copy surfaced when the WU-16 coverage-snapshot
    /// CSV / JSON pair fails to write. Mechanism description per ARCH §1.3.
    /// Pinned by `MatchExportServiceFailureTests`.
    static let coverageSnapshotWriteFailureToastMessage = "Could not save the coverage snapshot."

    /// Copy surfaced when the share sheet is
    /// withheld because a screen capture or mirroring signal is active at
    /// the moment of presentation. Mechanism description —
    /// names the observed trigger and the response, no outcome promise.
    static let shareWhileShieldedToastMessage = "Screen recording detected. Export paused."

    /// Write CSV + JSON to the hardened per-session temp directory and
    /// present `UIActivityViewController`. Both temp files are unlinked
    /// when the share sheet dismisses. The CSV / JSON serialization and
    /// the two atomic file writes run inside a `Task.detached` so a
    /// thousands-record audit doesn't freeze MainActor on
    /// serialization + I/O.
    ///
    /// Audit-leak guard: the artifacts land in
    /// `tempDirectory` (the SEC-2 `redacted_session_<UUID>/` subdirectory,
    /// backup-excluded at directory level) instead of the bare
    /// `FileManager.default.temporaryDirectory`.
    ///
    /// S6 / C10: `UIActivityViewController` is a UIKit surface outside
    /// SwiftUI's `.privacySensitive()` / shield system entirely — the
    /// available mitigation is the SEC-4-style intercept below: when
    /// `captureMonitor.isShielded` at the moment of presentation, the
    /// share is withheld, the just-written pair is unlinked, and an
    /// `.info` toast explains why.
    @MainActor
    static func share(
        records: [MatchAuditRecord],
        metadata: ExportMetadata,
        includeSensitive: Bool,
        documentName: String,
        tempDirectory: TempExportDirectory,
        captureMonitor: ScreenCaptureMonitor,
        toastManager: ToastQueueManager,
        from presenter: UIViewController
    ) async {
        do {
            // Idempotent; the coordinator may not have created the session
            // directory yet.
            try tempDirectory.prepare()
        } catch { // LegalPhrases:safe (Swift keyword)
            toastManager.enqueue(Self.triageWriteFailureToastMessage, severity: .error)
            return
        }
        guard let pair = await writeTriageExport(
            records: records,
            metadata: metadata,
            includeSensitive: includeSensitive,
            documentName: documentName,
            into: tempDirectory.url,
            toastManager: toastManager
        ) else { return }

        guard !captureMonitor.isShielded else {
            try? FileManager.default.removeItem(at: pair.csv)
            try? FileManager.default.removeItem(at: pair.json)
            toastManager.enqueue(Self.shareWhileShieldedToastMessage, severity: .info)
            return
        }

        let activity = UIActivityViewController(
            activityItems: [pair.csv, pair.json],
            applicationActivities: nil
        )
        // C-K lifecycle contract (dossier §4): the pair is unlinked on share
        // dismiss by this handler. If it does not fire (app killed before
        // dismissal), `cleanOrphanedTempFiles()` removes the files at next
        // launch within the 1-hour TTL — the enclosing `redacted_session_…/`
        // subtree matches the `redacted_` prefix and `resecta_audit_*`
        // matches the `resecta_` prefix. While they exist the files are
        // protected at `.complete` (SEC-1, best-effort) and live in
        // the SEC-2 backup-excluded session subdirectory. A `removeItem`
        // failure here leaves the file at `.complete` until that sweep — a
        // known-bounded residual (dossier §4 trace 4).
        activity.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: pair.csv)
            try? FileManager.default.removeItem(at: pair.json)
        }
        activity.popoverPresentationController?.sourceView = presenter.view
        presenter.present(activity, animated: true)
    }

    /// Pkg C / ERR-01 + ERR-02 testable seam: serialize records and write
    /// the CSV / JSON pair to a caller-provided directory, surfacing a
    /// `.error` toast on failure. Returns the URL pair on success, nil on
    /// failure. Exposed `internal` so `MatchExportServiceFailureTests` can
    /// pass a read-only directory or unencodable metadata and assert the
    /// toast enqueue without invoking `UIActivityViewController`.
    /// Production calls pass `TempExportDirectory.url` (S6 audit-leak fix).
    @MainActor
    static func writeTriageExport(
        records: [MatchAuditRecord],
        metadata: ExportMetadata,
        includeSensitive: Bool,
        documentName: String,
        into directory: URL,
        toastManager: ToastQueueManager
    ) async -> (csv: URL, json: URL)? {
        let stamp = timestamp()
        let slug = filenameSlug(documentName)
        let base = "resecta_audit_\(slug)_\(stamp)"
        let csvURL = directory.appendingPathComponent("\(base).csv")
        let jsonURL = directory.appendingPathComponent("\(base).json")

        let writeSucceeded: Bool = await Task.detached(priority: .utility) {
            let csvData = MatchAuditExporter.csv(
                records, metadata: metadata, includeSensitive: includeSensitive
            )
            do {
                let jsonData = try MatchAuditExporter.json(
                    records, metadata: metadata, includeSensitive: includeSensitive
                )
                try csvData.write(to: csvURL, options: [.atomic])
                try jsonData.write(to: jsonURL, options: [.atomic])
                // SEC-1: harden the just-written pair, best-effort.
                try? TempFileHardening.applyProtection(csvURL, level: .complete)
                try? TempFileHardening.applyProtection(jsonURL, level: .complete)
                // SEC-2: per-file backup exclusion. These
                // already live in the SEC-2 `redacted_session_<UUID>/`
                // subdirectory (excluded at the directory level), so the
                // per-file flag is belt-and-suspenders for the share artifacts.
                Self.excludeFromBackup(csvURL)
                Self.excludeFromBackup(jsonURL)
                return true
            } catch { // LegalPhrases:safe (Swift keyword)
                try? FileManager.default.removeItem(at: csvURL)
                try? FileManager.default.removeItem(at: jsonURL)
                return false
            }
        }.value

        guard writeSucceeded else {
            // Pkg C / ERR-01, ERR-02: previously a silent return — the
            // share-sheet path was indistinguishable from a UI bug. Surface
            // a Tier 1 `.error` toast (top, red). Covers both the file-write
            // failure path and (post-Pkg-C) the JSON-encoder throw path.
            toastManager.enqueue(Self.triageWriteFailureToastMessage, severity: .error)
            return nil
        }
        return (csv: csvURL, json: jsonURL)
    }

    // MARK: - WU-16 Coverage Snapshot Share

    /// WU-16: serialize a `CoverageReport` to counts-only CSV. Matched
    /// text is never written here; the per-category section enumerates
    /// only `(category.rawValue, candidateCount, overlapSuppressedCount)`.
    /// Test invariant: assert no substring match against any
    /// `result.matchedText` in the share payload.
    // `nonisolated` so the serializers run inside
    // `writeCoverageSnapshot`'s `Task.detached` block (off MainActor). They
    // are pure transforms of value-type inputs; callable from any isolation.
    nonisolated static func coverageSnapshotCSV(
        _ report: CoverageReport,
        metadata: ExportMetadata
    ) -> Data {
        var lines: [String] = []
        lines.append("# Resecta — Scan coverage snapshot")
        lines.append("# schemaVersion=\(metadata.schemaVersion)  preset=\(metadata.presetName)  app=\(metadata.appVersion)")
        lines.append("")
        lines.append("metric,value")
        lines.append("scannedPages,\(report.scannedPageCount)")
        lines.append("enabledCategories,\(report.enabledCategories.count)")
        lines.append("totalCandidates,\(report.candidateCountByCategory.values.reduce(0, +))")
        lines.append("applied,\(report.appliedCount)")
        lines.append("deselected,\(report.deselectedCount)")
        lines.append("belowThreshold,\(report.belowThresholdSuppressedCount)")
        let overlap = report.overlapSuppressedCountByCategory.values.reduce(0, +)
        lines.append("overlapSuppressed,\(overlap)")
        lines.append("")
        lines.append("category,candidateCount,overlapSuppressedCount")
        let categories = PIICategory.allCases.filter {
            (report.candidateCountByCategory[$0] ?? 0) > 0
            || (report.overlapSuppressedCountByCategory[$0] ?? 0) > 0
        }
        for cat in categories {
            let candidates = report.candidateCountByCategory[cat] ?? 0
            let suppressed = report.overlapSuppressedCountByCategory[cat] ?? 0
            lines.append("\(cat.rawValue),\(candidates),\(suppressed)")
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// WU-16: serialize a `CoverageReport` to counts-only JSON. Same
    /// privacy invariant as `coverageSnapshotCSV`.
    nonisolated static func coverageSnapshotJSON(
        _ report: CoverageReport,
        metadata: ExportMetadata
    ) -> Data {
        let candidatesByCategory: [String: Int] = report.candidateCountByCategory
            .reduce(into: [:]) { $0[$1.key.rawValue] = $1.value }
        let overlapByCategory: [String: Int] = report.overlapSuppressedCountByCategory
            .reduce(into: [:]) { $0[$1.key.rawValue] = $1.value }
        let payload: [String: Any] = [
            "schemaVersion": Int(metadata.schemaVersion),
            "exportedAt": ISO8601DateFormatter().string(from: metadata.exportedAt),
            "appVersion": metadata.appVersion,
            "preset": metadata.presetName,
            "scannedPages": report.scannedPageCount,
            "enabledCategories": report.enabledCategories.map(\.rawValue).sorted(),
            "totalCandidates": report.candidateCountByCategory.values.reduce(0, +),
            "candidatesByCategory": candidatesByCategory,
            "applied": report.appliedCount,
            "deselected": report.deselectedCount,
            "belowThreshold": report.belowThresholdSuppressedCount,
            "overlapSuppressedByCategory": overlapByCategory,
        ]
        return (try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data()
    }

    /// WU-16: write counts-only CSV+JSON to temp + present
    /// `UIActivityViewController`. Mirrors `share` for the temp-file +
    /// activity-view-controller plumbing; payload is structurally
    /// different (no per-match data) so it ships through this dedicated
    /// entry point. No new user-facing share surface — same
    /// system share sheet.
    @MainActor
    static func shareCoverageSnapshot(
        report: CoverageReport,
        metadata: ExportMetadata,
        toastManager: ToastQueueManager,
        from presenter: UIViewController
    ) async {
        guard let pair = await writeCoverageSnapshot(
            report: report,
            metadata: metadata,
            into: FileManager.default.temporaryDirectory,
            toastManager: toastManager
        ) else { return }
        let csvURL = pair.csv
        let jsonURL = pair.json

        let activity = UIActivityViewController(
            activityItems: [csvURL, jsonURL],
            applicationActivities: nil
        )
        // C-K lifecycle contract (dossier §4): the pair is unlinked on share
        // dismiss by this handler. If it does not fire (app killed before
        // dismissal), `cleanOrphanedTempFiles()` removes the files at next
        // launch within the 1-hour TTL (the `resecta_` prefix matches
        // `resecta_coverage_*`). While they exist the files are protected at
        // `.complete` (SEC-1, best-effort) and excluded from backup
        // per-file (SEC-2) — coverage shares write to flat
        // `temporaryDirectory`, not a SEC-2 session subdirectory. A
        // `removeItem` failure here leaves the file at `.complete` until that
        // sweep — a known-bounded residual (dossier §4 trace 4).
        activity.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: csvURL)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        activity.popoverPresentationController?.sourceView = presenter.view
        presenter.present(activity, animated: true)
    }

    /// Pkg C / ERR-04 testable seam: serialize the coverage report and
    /// write the CSV / JSON pair to a caller-provided directory, surfacing
    /// a `.error` toast on failure. Returns the URL pair on success, nil
    /// on failure. Exposed `internal` so `MatchExportServiceFailureTests`
    /// can pass a read-only directory and assert the toast enqueue without
    /// invoking `UIActivityViewController`. Production calls pass
    /// `FileManager.default.temporaryDirectory`.
    @MainActor
    static func writeCoverageSnapshot(
        report: CoverageReport,
        metadata: ExportMetadata,
        into directory: URL,
        toastManager: ToastQueueManager
    ) async -> (csv: URL, json: URL)? {
        let stamp = timestamp()
        let base = "resecta_coverage_\(stamp)"
        let csvURL = directory.appendingPathComponent("\(base).csv")
        let jsonURL = directory.appendingPathComponent("\(base).json")

        // Serialize + write off MainActor. A large CoverageReport's
        // CSV/JSON serialization plus the two atomic writes can stall the UI
        // thread on big documents; mirror writeTriageExport's Task.detached
        // pattern instead of running synchronously on MainActor.
        let writeSucceeded: Bool = await Task.detached(priority: .utility) {
            let csvData = Self.coverageSnapshotCSV(report, metadata: metadata)
            let jsonData = Self.coverageSnapshotJSON(report, metadata: metadata)
            do {
                try csvData.write(to: csvURL, options: [.atomic])
                try jsonData.write(to: jsonURL, options: [.atomic])
                // SEC-1: harden the just-written pair, best-effort.
                try? TempFileHardening.applyProtection(csvURL, level: .complete)
                try? TempFileHardening.applyProtection(jsonURL, level: .complete)
                // SEC-2: per-file backup exclusion — coverage
                // share files write to flat `temporaryDirectory` (no SEC-2
                // session subdirectory), so the per-file flag is the exclusion.
                Self.excludeFromBackup(csvURL)
                Self.excludeFromBackup(jsonURL)
                return true
            } catch { // LegalPhrases:safe (Swift keyword)
                try? FileManager.default.removeItem(at: csvURL)
                try? FileManager.default.removeItem(at: jsonURL)
                return false
            }
        }.value

        guard writeSucceeded else {
            // Pkg C / ERR-04: previously a silent return — surface a Tier 1
            // `.error` toast (top, red) so the user knows the coverage
            // snapshot did not reach the share sheet.
            toastManager.enqueue(Self.coverageSnapshotWriteFailureToastMessage, severity: .error)
            return nil
        }
        return (csv: csvURL, json: jsonURL)
    }

    /// Resolve the topmost presented view controller for modally-attached
    /// sheets (the active scene's rootViewController is usually covered
    /// by the Search sheet itself).
    @MainActor
    static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
            let root = scene.keyWindow?.rootViewController else {
            return nil
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    // MARK: - Helpers

    /// SEC-2: exclude a single share-sheet temp file from
    /// iCloud / local backup. The export share files are transient (unlinked
    /// on dismiss) and have no `TempExportDirectory` lifecycle owner, so the
    /// directory-level exclusion `TempExportDirectory.prepare()` applies is
    /// unavailable here; the per-file flag is the chosen mechanism. Best-effort (`try?`),
    /// mirroring the directory-level call in `TempExportDirectory.prepare()`.
    /// `nonisolated` so it can run inside the `Task.detached` write blocks.
    nonisolated private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    private static func timestamp() -> String {
        // Filename-safe flavor of ISO 8601 (replace ":" for filesystem sanity).
        // Date.ISO8601FormatStyle is Sendable, unlike ISO8601DateFormatter.
        Date().formatted(.iso8601.year().month().day()
            .timeSeparator(.colon)
            .time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
    }

    /// Filename-safe slug for the document name. Strips the extension,
    /// keeps only alphanumerics + hyphens + underscores, caps at 40 chars
    /// so the final filename is comfortably under common filesystem
    /// limits even with the timestamp suffix.
    private static func filenameSlug(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = base
            .unicodeScalars
            .map { allowed.contains(Character($0)) ? Character($0) : "_" }
        let collapsed = String(cleaned).replacingOccurrences(
            of: "_+", with: "_", options: .regularExpression
        )
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let final = trimmed.isEmpty ? "document" : String(trimmed.prefix(40))
        return final
    }
}

// MARK: - App version accessor

extension Bundle {
    /// "1.0.0 (42)" — marketing version + build number — for
    /// `ExportMetadata.appVersion`. Nil-safe fallbacks so the audit
    /// doesn't crash on an unexpected Info.plist shape.
    var appVersion: String {
        let marketing = infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(marketing) (\(build))"
    }
}
