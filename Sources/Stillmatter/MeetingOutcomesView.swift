import SwiftUI

struct MeetingOutcomeRow: Identifiable {
    let id: String
    let text: String
    let detail: String
    let citations: [(label: String, segmentID: String, seconds: Double?)]
}

struct MeetingOutcomeGroup: Identifiable {
    let id: String
    let title: String
    let note: String
    let rows: [MeetingOutcomeRow]
}

struct MeetingOutcomesView: View {
    let groups: [MeetingOutcomeGroup]
    let canEdit: Bool
    let copy: (String) -> Void
    let edit: () -> Void
    let seek: (String, Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if groups.isEmpty {
                Text("No structured cited outcomes available.").foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(group.title).font(.system(size: 18, weight: .semibold))
                        Spacer()
                        Text(group.note).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(group.rows) { row in
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.text).font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 3) {
                                    if !row.detail.isEmpty {
                                        Text(row.detail).foregroundStyle(.secondary)
                                    }
                                    ForEach(Array(row.citations.enumerated()), id: \.offset) { _, citation in
                                        if let seconds = citation.seconds {
                                            Button("↗ \(citation.label) source") { seek(citation.segmentID, seconds) }
                                                .buttonStyle(.plain).foregroundStyle(.blue)
                                        } else {
                                            Text("Source · seek unavailable").foregroundStyle(.secondary)
                                        }
                                    }
                                }.font(.system(size: 12))
                            }
                            Button("Copy") { copy(row.text) }
                            Button("Edit", action: edit).disabled(!canEdit)
                        }
                        .buttonStyle(.bordered)
                        .padding(.vertical, 14)
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
