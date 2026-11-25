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
    /// the app-wide store, as a seam testable without hosting the sheet.
    static func commitSaveCurrentRegex(
        label: String,
        pattern: String,
        store: SavedRegexStore
    ) async -> PatternAdmission.Outcome {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmedLabel.isEmpty, !trimmedPattern.isEmpty else {
            return .refused(message: "Label and pattern must not be empty.")
        }
        guard await PatternAdmission.sentinelAdmits(trimmedPattern) else {
            return .refused(message: PatternAdmission.sentinelRejectedMessage)
        }
        return PatternAdmission.outcome(of: store.add(label: trimmedLabel, pattern: trimmedPattern))
    }

    /// Alert "Save" action: toast success, or show the alert again.
    func saveCurrentRegex() async {
        switch await Self.commitSaveCurrentRegex(
            label: savedRegexSaveLabel,
            pattern: searchState.queryText,
            store: savedRegexStore
        ) {
        case .added:
            savedRegexSaveLabel = ""
            savedRegexSaveError = nil
            toastManager.post(.savedRegexSaved)
        case .refused(let message):
            savedRegexSaveError = message
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showSavedRegexSavePrompt = true
        case .notSaved:
            savedRegexSaveError = ListChange.notSavedMessage
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showSavedRegexSavePrompt = true
        }
    }
}
