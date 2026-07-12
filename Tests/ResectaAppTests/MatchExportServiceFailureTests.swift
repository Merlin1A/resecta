import Testing
import Foundation
import UIKit
import RedactionEngine
@testable import ResectaApp

// Pkg C / ERR-01, ERR-02, ERR-04 — share-export failure toast wiring.
// Today the audit CSV/JSON share path silently returns when the temp
// write fails; the share-sheet path is then indistinguishable from a UI
// bug. Pkg C wires a Tier 1 `.error` toast (top, red) onto the error
// path. The `writeTriageExport(...into:toastManager:)` and
// `writeCoverageSnapshot(...into:toastManager:)` testable seams take a
// caller-provided directory so we can pass one that is read-only (or
// nonexistent) and assert the toast enqueue without invoking
// `UIActivityViewController`.

@Suite("MatchExportService failure-toast wiring (Pkg C)")
@MainActor
struct MatchExportServiceFailureTests {

    // MARK: - Copy

    @Test("Triage write-failure toast copy is mechanism description (ARCH §1.3)")
    func triageWriteFailureToastCopy() {
        #expect(MatchExportService.triageWriteFailureToastMessage
                == "Could not save the match audit log.")
    }

    @Test("Coverage-snapshot write-failure toast copy is mechanism description")
    func coverageSnapshotWriteFailureToastCopy() {
        #expect(MatchExportService.coverageSnapshotWriteFailureToastMessage
                == "Could not save the coverage snapshot.")
    }

    // MARK: - Triage CSV / JSON failure path

    @Test("Triage write into a nonexistent directory enqueues an .error toast")
    func testCSVWriteFailureEnqueuesErrorToast() async {
        let toastManager = ToastQueueManager()
        // A nonexistent directory under `/dev/null/...` cannot accept
        // writes — `Data.write(to:options:)` throws `CocoaError`. The
        // error path returns nil and enqueues the failure toast.
        let badDirectory = URL(fileURLWithPath: "/dev/null/pkg-c-nonexistent")
        let result = await MatchExportService.writeTriageExport(
            records: makeRecords(),
            metadata: makeMetadata(),
            includeSensitive: false,
            documentName: "document",
            into: badDirectory,
            toastManager: toastManager
        )
        #expect(result == nil)
        #expect(toastManager.activeToasts.count == 1)
        let toast = toastManager.activeToasts.first
        #expect(toast?.message == MatchExportService.triageWriteFailureToastMessage)
        #expect(toast?.severity == .error)
        #expect(toast?.severity.position == .top)
    }

    @Test("Triage path with unencodable metadata throws JSON encoder → enqueues .error toast")
    func testJSONEncodeFailureEnqueuesErrorToast() async {
        let toastManager = ToastQueueManager()
        // Inject `Double.nan` into `perCategoryOverrides` so
        // `MatchAuditExporter.json` throws on encode (default
        // `JSONEncoder.NonConformingFloatEncodingStrategy.throw`). The
        // shared error block surfaces the triage-write-failure toast
        // even though the file write itself never ran.
        let unencodableMetadata = ExportMetadata(
            schemaVersion: 4,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1.0.0 (42)",
            presetName: "Default",
            perCategoryOverrides: ["Name": .nan],
            documentName: "document",
            totalMatches: 1,
            appliedMatches: 1
        )
        // A writable directory; the failure is engine-side, not I/O-side.
        let tmp = FileManager.default.temporaryDirectory
        let result = await MatchExportService.writeTriageExport(
            records: makeRecords(),
            metadata: unencodableMetadata,
            includeSensitive: false,
            documentName: "document",
            into: tmp,
            toastManager: toastManager
        )
        #expect(result == nil)
        #expect(toastManager.activeToasts.first?.message
                == MatchExportService.triageWriteFailureToastMessage)
        #expect(toastManager.activeToasts.first?.severity == .error)
    }

    @Test("Triage happy path writes both files and does not enqueue any toast")
    func testTriageHappyPathNoToast() async {
        let toastManager = ToastQueueManager()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-c-happy-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = await MatchExportService.writeTriageExport(
            records: makeRecords(),
            metadata: makeMetadata(),
            includeSensitive: false,
            documentName: "document",
            into: tmp,
            toastManager: toastManager
        )
        #expect(result != nil)
        #expect(toastManager.activeToasts.isEmpty)
        if let pair = result {
            #expect(FileManager.default.fileExists(atPath: pair.csv.path))
            #expect(FileManager.default.fileExists(atPath: pair.json.path))
        }
    }

    // MARK: - Coverage snapshot failure path

    @Test("Coverage snapshot write into a nonexistent directory enqueues an .error toast")
    func testCoverageSnapshotWriteFailureEnqueuesErrorToast() async {
        let toastManager = ToastQueueManager()
        let badDirectory = URL(fileURLWithPath: "/dev/null/pkg-c-nonexistent")
        let result = await MatchExportService.writeCoverageSnapshot(
            report: makeCoverageReport(),
            metadata: makeMetadata(),
            into: badDirectory,
            toastManager: toastManager
        )
        #expect(result == nil)
        #expect(toastManager.activeToasts.count == 1)
        let toast = toastManager.activeToasts.first
        #expect(toast?.message == MatchExportService.coverageSnapshotWriteFailureToastMessage)
        #expect(toast?.severity == .error)
        #expect(toast?.severity.position == .top)
    }

    @Test("Coverage snapshot happy path writes both files and does not enqueue any toast")
    func testCoverageSnapshotHappyPathNoToast() async {
        let toastManager = ToastQueueManager()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-c-cov-happy-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = await MatchExportService.writeCoverageSnapshot(
            report: makeCoverageReport(),
            metadata: makeMetadata(),
            into: tmp,
            toastManager: toastManager
        )
        #expect(result != nil)
        #expect(toastManager.activeToasts.isEmpty)
    }

    // MARK: - S6 audit-leak fix + C10 share intercept (design 04)

    @Test("Shielded-share toast copy is mechanism description (ARCH §1.3)")
    func testShareWhileShieldedToastCopy() {
        #expect(MatchExportService.shareWhileShieldedToastMessage
                == "Screen recording detected. Export paused.")
    }

    @Test("Triage export pair lands inside the hardened session directory")
    func testTempFilesWrittenToHardenedPath() async throws {
        let toastManager = ToastQueueManager()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("s6-hardened-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let tempDirectory = TempExportDirectory(parent: parent)
        try tempDirectory.prepare()

        let result = await MatchExportService.writeTriageExport(
            records: makeRecords(),
            metadata: makeMetadata(),
            includeSensitive: false,
            documentName: "document",
            into: tempDirectory.url,
            toastManager: toastManager
        )
        let pair = try #require(result)
        // Both artifacts live under the SEC-2 `redacted_session_<UUID>/`
        // subdirectory — not the bare temp root.
        #expect(pair.csv.path.hasPrefix(tempDirectory.url.path))
        #expect(pair.json.path.hasPrefix(tempDirectory.url.path))
        #expect(tempDirectory.url.lastPathComponent
            .hasPrefix(TempExportDirectory.sessionDirectoryPrefix))
        #expect(FileManager.default.fileExists(atPath: pair.csv.path))
        #expect(FileManager.default.fileExists(atPath: pair.json.path))
    }

    @Test("Adversarial: share is withheld while shielded — no presentation, pair unlinked, .info toast")
    func testShareSheetBlockedWhenShielded() async throws {
        let toastManager = ToastQueueManager()
        let monitor = ScreenCaptureMonitor()
        monitor._setForTesting(isCaptured: true, isMirroring: false)

        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("s6-shielded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let tempDirectory = TempExportDirectory(parent: parent)

        let presenter = UIViewController()
        await MatchExportService.share(
            records: makeRecords(),
            metadata: makeMetadata(),
            includeSensitive: false,
            documentName: "document",
            tempDirectory: tempDirectory,
            captureMonitor: monitor,
            toastManager: toastManager,
            from: presenter
        )

        // UIActivityViewController was never presented.
        #expect(presenter.presentedViewController == nil)
        // The intercept explains itself with the mechanism-description copy.
        #expect(toastManager.activeToasts.first?.message
                == MatchExportService.shareWhileShieldedToastMessage)
        #expect(toastManager.activeToasts.first?.severity == .info)
        // share() routed through the hardened directory (prepare ran)…
        #expect(FileManager.default.fileExists(atPath: tempDirectory.url.path))
        // …and the just-written pair was unlinked on abort, so nothing
        // redacted-adjacent lingers on disk.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.url.path)
        #expect(leftovers.isEmpty)
    }

    // MARK: - SEC-1 / SEC-2 hardening on share-export writes (C-K / CAT-115)

    /// SEC-1 read-back tolerant of the iOS-Simulator coalescing of
    /// `.complete` → `.completeUntilFirstUserAuthentication` (and macOS hosts
    /// that report nil). The load-bearing red→green for CAT-115 is the
    /// `isExcludedFromBackup` flag below — that is NOT coalesced on the sim.
    private func expectProtectionAtLeastComplete(_ url: URL) throws {
        guard let current = try TempFileHardening.currentProtection(of: url) else { return }
        #expect([.complete, .completeUntilFirstUserAuthentication].contains(current))
    }

    @Test("Triage export pair is hardened — file-protection applied + excluded from backup (CAT-115)")
    func testTriageExportWriteAppliesProtection() async throws {
        let toastManager = ToastQueueManager()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("catk-triage-prot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let tempDirectory = TempExportDirectory(parent: parent)
        try tempDirectory.prepare()

        let pair = try #require(await MatchExportService.writeTriageExport(
            records: makeRecords(),
            metadata: makeMetadata(),
            includeSensitive: false,
            documentName: "document",
            into: tempDirectory.url,
            toastManager: toastManager
        ))

        for url in [pair.csv, pair.json] {
            // SEC-2 (D-20): the per-file backup-exclusion flag reads back
            // true. This flag is not coalesced on the simulator, so it is the
            // genuine red→green: unset at pin, true after CAT-115.
            let backup = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup
            #expect(backup == true)
            try expectProtectionAtLeastComplete(url)
        }
    }

    @Test("Coverage snapshot pair is hardened — file-protection applied + excluded from backup (CAT-115)")
    func testCoverageSnapshotWriteAppliesProtection() async throws {
        let toastManager = ToastQueueManager()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("catk-cov-prot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pair = try #require(await MatchExportService.writeCoverageSnapshot(
            report: makeCoverageReport(),
            metadata: makeMetadata(),
            into: tmp,
            toastManager: toastManager
        ))

        for url in [pair.csv, pair.json] {
            // Flat `temporaryDirectory` (no SEC-2 session subdirectory), so
            // the per-file flag is the only backup exclusion — unset at pin,
            // true after CAT-115.
            let backup = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup
            #expect(backup == true)
            try expectProtectionAtLeastComplete(url)
        }
    }

    // MARK: - Fixtures

    private func makeRecords() -> [MatchAuditRecord] {
        [MatchAuditRecord(
            id: UUID(),
            pageIndex: 0,
            matchedText: "Acme",
            source: "textLayer",
            piiCategory: "Name",
            piiConfidence: 0.91,
            term: "PII Scan",
            ruleID: "name.nltagger",
            finalScore: 0.91,
            appliedThreshold: 0.70,
            rationaleSummary: "regex(name.nltagger)",
            isSelected: true,
            wasApplied: true
        )]
    }

    private func makeMetadata() -> ExportMetadata {
        ExportMetadata(
            schemaVersion: 4,
            appVersion: "1.0.0 (1)",
            presetName: "Default",
            perCategoryOverrides: [:],
            documentName: "document",
            totalMatches: 1,
            appliedMatches: 1
        )
    }

    private func makeCoverageReport() -> CoverageReport {
        CoverageReport(
            scannedPageCount: 4,
            enabledCategories: [.ssn, .email],
            candidateCountByCategory: [.ssn: 2, .email: 1],
            appliedCount: 1,
            deselectedCount: 0,
            belowThresholdSuppressedCount: 1,
            overlapSuppressedCountByCategory: [:],
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
