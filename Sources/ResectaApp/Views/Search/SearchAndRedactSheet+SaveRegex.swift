import SwiftUI
import UIKit

extension SearchAndRedactSheet {
    // MARK: - Save current regex

    /// The alert's own title — previously borrowed the "Save
    /// current..." menu item's label text; the alert isn't a menu, so
    /// it gets independent copy. The menu item itself is unchanged.
    static let saveCurrentRegexAlertTitle = "Save current pattern"

    /// Success toast for a committed "Save current..." — names where the
    /// saved pattern is managed so the save isn't a dead end.
    /// SAFE copy — factual destination, no outcome promise.
    static let savedRegexSavedToast = "Saved — manage in Settings → Saved Regexes"

    /// Sentinel-validate then commit a "Save current..." request against
    /// the app-wide store. Returns nil on success, or the user-facing
    /// error message to re-present in the naming alert. Static seam so
    /// the full round-trip (validate → `SavedRegexStore.add` → persist)
    /// is unit-testable without hosting the sheet.
    static func commitSaveCurrentRegex(
        label: String,
        pattern: String,
        store: SavedRegexStore
    ) async -> String? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmedLabel.isEmpty, !trimmedPattern.isEmpty else {
            return "Label and pattern must not be empty."
        }
        let accepted = await PatternAdmission.sentinelAdmits(trimmedPattern)
        guard accepted else {
            return String(
                localized: "profile.regex.sentinel.rejected",
                table: "Legal",
                bundle: .main
            )
        }
        guard store.add(label: trimmedLabel, pattern: trimmedPattern) else {
            return PatternAdmission.storeRejectedMessage
        }
        return nil
    }

    /// Alert "Save" action: commit, then either toast success (naming
    /// the management surface) or re-present the alert with the error.
    func saveCurrentRegex() async {
        let error = await Self.commitSaveCurrentRegex(
            label: savedRegexSaveLabel,
            pattern: searchState.queryText,
            store: savedRegexStore
        )
        if let error {
            savedRegexSaveError = error
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showSavedRegexSavePrompt = true
        } else {
            savedRegexSaveLabel = ""
            savedRegexSaveError = nil
            toastManager.post(.savedRegexSaved)
        }
    }
}
