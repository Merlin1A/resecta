import SwiftUI

/// The details of the notice place: every line that holds, whole, in rank
/// order: the pages not searched in the shared list with its header, then the
/// others in a second list without one. A page chip closes the details, shows
/// that page and parks the Search sheet. When no line holds any longer the
/// details close.
struct NotSearchedDetailsSheet: View {
    let lines: [SearchNoticeLine]
    let captureMonitor: ScreenCaptureMonitor
    let goToPage: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let content = SearchNoticePlace.detailsContent(lines)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    NotSearchedList(content: content.notSearched, showsHeader: true, goToPage: goToPage)
                    NotSearchedList(content: content.others, showsHeader: false, goToPage: goToPage)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onChange(of: lines.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
        .accessibilityIdentifier("noticeDetailsSheet")
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Page numbers are the document's, and the details stand above the
        // Search sheet's own cover, so they carry their own screen-capture
        // shield, with the monitor passed in as a let.
        .shieldedSheetContent(monitor: captureMonitor)
    }
}
