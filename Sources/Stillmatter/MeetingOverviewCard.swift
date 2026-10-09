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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                Text(title).font(.system(size: 19, weight: .semibold))
                Spacer()
                Button("Expand ↗", action: expand).disabled(!canEdit)
                Button("Edit", action: edit).disabled(!canEdit)
                Button("Copy", action: copy).disabled(content.isEmpty)
            }
            .buttonStyle(.bordered)
            Text(content.isEmpty ? unavailable : content)
                .font(.system(size: 15))
                .foregroundStyle(content.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.11, green: 0.17, blue: 0.19))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.13)))
    }
}
