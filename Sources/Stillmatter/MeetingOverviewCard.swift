import SwiftUI

/// Readable meeting content, with the existing workspace editor revealed only on demand.
struct MeetingOverviewCard: View {
    let title: String
    let content: String
    let unavailable: String
    let canEdit: Bool
    let expand: () -> Void
    let edit: () -> Void
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GraphiteFocusPresentation.Space.panel) {
            HStack(alignment: .center, spacing: GraphiteFocusPresentation.Space.compact) {
                Text(title).font(GraphiteFocusSwiftUI.sectionHeading)
                Spacer()
                Button("Expand ↗", action: expand).disabled(!canEdit)
                Button("Edit", action: edit).disabled(!canEdit)
                Button("Copy", action: copy).disabled(content.isEmpty)
            }
            .buttonStyle(.bordered)
            Text(content.isEmpty ? unavailable : content)
                .font(GraphiteFocusSwiftUI.body)
                .foregroundStyle(content.isEmpty ? GraphiteFocusSwiftUI.secondary : GraphiteFocusSwiftUI.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .graphitePanel()
    }
}
