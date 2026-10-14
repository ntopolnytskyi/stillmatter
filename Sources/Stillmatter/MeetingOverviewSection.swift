import SwiftUI

/// Open Meeting detail section with a shared heading/action row.
/// The existing workspace editor is revealed only on demand.
struct MeetingOverviewSection: View {
    @Environment(\.graphiteFocusColors) private var colors
    let title: String
    let content: String
    let unavailable: String
    let canEdit: Bool
    let expand: () -> Void
    let edit: () -> Void
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GraphiteFocusPresentation.Space.compact) {
            HStack(alignment: .center, spacing: GraphiteFocusPresentation.Space.compact) {
                Text(title).font(GraphiteFocusSwiftUI.sectionHeading)
                Spacer()
                Button("Expand ↗", action: expand).disabled(!canEdit)
                Button("Edit", action: edit).disabled(!canEdit)
                Button("Copy", action: copy).disabled(content.isEmpty)
            }
            .buttonStyle(.bordered)
            Divider()
            Text(content.isEmpty ? unavailable : content)
                .font(GraphiteFocusSwiftUI.body)
                .foregroundStyle(Color(nsColor: content.isEmpty ? colors.textSecondary : colors.textPrimary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, GraphiteFocusPresentation.Space.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Color(nsColor: colors.textPrimary))
        .environment(\.colorScheme, .dark)
        .graphiteSemanticContext()
    }
}
