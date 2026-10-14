import AppKit
import SwiftUI

struct MeetingOutcomeRow: Identifiable {
    let id: String
    let text: String
    let detail: String
    let citations: [(label: String, segmentID: String, startSeconds: Double, endSeconds: Double, seconds: Double?)]
}

struct MeetingOutcomeGroup: Identifiable {
    enum Kind: String {
        case mine
        case others
        case decisions
        case questions

        var isReviewWorkspace: Bool { self == .mine }

        var timelineKind: MeetingTimelineMoment.Kind {
            switch self {
            case .mine, .others: return .action
            case .decisions: return .decision
            case .questions: return .transcript
            }
        }
    }

    let kind: Kind
    let title: String
    let note: String
    let rows: [MeetingOutcomeRow]
    var id: String { kind.rawValue }
}

struct MeetingOutcomesView: View {
    @Environment(\.graphiteFocusColors) private var colors
    let groups: [MeetingOutcomeGroup]
    let canEdit: Bool
    let copy: (String) -> Void
    let edit: () -> Void
    let seek: (String, Double) -> Void
    let draft: (String) -> (title: String, comment: String)?
    let save: (String, String, String) throws -> Void
    let review: (String, Bool) throws -> Void
    @State private var active: MeetingOutcomeRow?
    @State private var reviewing = false
    @State private var title = ""
    @State private var comment = ""
    @State private var error = ""
    @State private var inlineSuccess = ""

    var body: some View {
        VStack(alignment: .leading, spacing: GraphiteFocusPresentation.Space.dense) {
            if !inlineSuccess.isEmpty {
                Text("✓ \(inlineSuccess)")
                    .font(GraphiteFocusSwiftUI.metadataFont)
                    .foregroundStyle(Color(nsColor: colors.success))
                    .accessibilityLabel(inlineSuccess)
            }
            if groups.isEmpty { Text("No structured cited outcomes available.").foregroundStyle(Color(nsColor: colors.textSecondary)) }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: GraphiteFocusPresentation.Space.flush) {
                    HStack {
                        Text(group.title).font(GraphiteFocusSwiftUI.sectionHeading)
                        Spacer()
                        Text(group.note).font(GraphiteFocusSwiftUI.metadataFont).foregroundStyle(Color(nsColor: colors.textMetadata))
                    }
                    ForEach(group.rows) { row in
                        HStack(alignment: .top, spacing: GraphiteFocusPresentation.Space.dense) {
                            VStack(alignment: .leading, spacing: GraphiteFocusPresentation.Space.primitive) {
                                Text(row.text).font(GraphiteFocusSwiftUI.rowTitle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: GraphiteFocusPresentation.Space.primitive) {
                                    Text(row.detail.isEmpty ? "Generated from meeting" : "Generated from meeting · \(row.detail)")
                                        .foregroundStyle(Color(nsColor: colors.textSecondary))
                                    ForEach(Array(row.citations.enumerated()), id: \.offset) { _, citation in
                                        if let seconds = citation.seconds {
                                            Button("↗ source \(citation.label)") { seek(citation.segmentID, seconds) }
                                                .buttonStyle(.borderless).foregroundStyle(Color(nsColor: colors.accent))
                                        } else { Text("Source · seek unavailable").foregroundStyle(Color(nsColor: colors.textMetadata)) }
                                    }
                                }.font(GraphiteFocusSwiftUI.metadataFont)
                            }
                            if group.kind.isReviewWorkspace {
                                Button("Edit") { open(row, reviewing: false) }.disabled(row.detail != "pending")
                                Button("Review") { open(row, reviewing: true) }.disabled(row.detail != "pending")
                            } else {
                                Button("Copy") { copy(row.text) }
                            }
                        }
                        .buttonStyle(.bordered).padding(.vertical, GraphiteFocusPresentation.Space.dense)
                        Divider()
                    }
                }
                .graphitePanel()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .graphiteSemanticContext()
        .sheet(item: $active) { row in
            VStack(alignment: .leading, spacing: GraphiteFocusPresentation.Space.dense) {
                Text(reviewing ? "Review my action" : "Edit my action").font(GraphiteFocusSwiftUI.sectionHeading)
                Text(reviewing ? "Accept creates a Todo Item. Decline dismisses this proposal." : "Save updates only the proposal; it does not accept or create a Todo Item.")
                    .font(GraphiteFocusSwiftUI.metadataFont).foregroundStyle(Color(nsColor: colors.textSecondary))
                Text("Provenance: Generated from meeting · \(row.detail)").font(GraphiteFocusSwiftUI.metadataFont)
                Text("Action item text")
                TextEditor(text: $title).frame(minHeight: 76) // graphite-focus-native-exception: minimum native multiline editor height
                Text("Comment")
                TextEditor(text: $comment).frame(minHeight: 56) // graphite-focus-native-exception: minimum native multiline editor height
                if !error.isEmpty {
                    Text("! Review failed. The proposal was not changed; try again. \(error)")
                        .foregroundStyle(Color(nsColor: colors.destructive))
                        .accessibilityLabel("Review failed. The proposal was not changed; try again. \(error)")
                }
                HStack {
                    Spacer()
                    Button("Cancel") { active = nil }
                    if reviewing {
                        Button("Accept") { commit(row, accept: true) }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Decline") { commit(row, accept: false) }
                    } else {
                        Button("Save") { commit(row, accept: nil) }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }.padding(GraphiteFocusPresentation.Space.page).frame(minWidth: 480) // graphite-focus-native-exception: sheet's minimum readable editor width
        }
    }

    private func open(_ row: MeetingOutcomeRow, reviewing: Bool) {
        self.reviewing = reviewing
        title = draft(row.id)?.title ?? row.text
        comment = draft(row.id)?.comment ?? ""
        error = ""
        active = row
    }

    private func commit(_ row: MeetingOutcomeRow, accept: Bool?) {
        do {
            if accept == nil || accept == true { try save(row.id, title, comment) }
            if let accept { try review(row.id, accept) }
            let message: String
            if accept == nil { message = "Changes saved." }
            else if accept == true { message = "Added ‘\(title)’ to Todos." }
            else { message = "Proposal dismissed." }
            active = nil
            showSuccess(message)
        } catch { self.error = error.localizedDescription }
    }

    private func showSuccess(_ message: String) {
        inlineSuccess = message
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [.announcement: message])
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if inlineSuccess == message { inlineSuccess = "" }
        }
    }
}
