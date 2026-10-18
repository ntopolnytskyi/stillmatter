import SwiftUI

/// Meaning-axis feedback only. Choice, interaction, and activity use their
/// native SwiftUI presentations independently.
struct GraphiteFocusStatusView: View {
    let meaning: GraphiteFocusStatusMeaning
    let text: String

    var body: some View {
        GraphiteFocusStatusContent(meaning: meaning, text: text)
            .graphiteSemanticContext()
    }
}

private struct GraphiteFocusStatusContent: View {
    let meaning: GraphiteFocusStatusMeaning
    let text: String
    @Environment(\.graphiteFocusColors) private var colors

    var body: some View {
        Text("\(meaning.symbol) \(text)")
            .font(GraphiteFocusSwiftUI.metadataFont)
            .foregroundStyle(Color(nsColor: meaning.color(in: colors)))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
            .accessibilityValue(text)
    }
}

struct GraphiteFocusInlineNotice: View {
    let title: String
    let detail: String
    let meaning: GraphiteFocusStatusMeaning

    var body: some View {
        GraphiteFocusInlineNoticeContent(title: title, detail: detail, meaning: meaning)
            .graphiteSemanticContext()
    }
}

private struct GraphiteFocusInlineNoticeContent: View {
    let title: String
    let detail: String
    let meaning: GraphiteFocusStatusMeaning
    @Environment(\.graphiteFocusColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: GraphiteFocusPresentation.Space.primitive) {
            GraphiteFocusStatusContent(meaning: meaning, text: title)
            Text(detail)
                .font(GraphiteFocusSwiftUI.body)
                .foregroundStyle(Color(nsColor: colors.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}

struct GraphiteFocusProgressStatus: View {
    let title: String
    let value: Double?
    let valueDescription: String

    var body: some View {
        GraphiteFocusProgressStatusContent(title: title, value: value, valueDescription: valueDescription)
            .graphiteSemanticContext()
    }
}

private struct GraphiteFocusProgressStatusContent: View {
    let title: String
    let value: Double?
    let valueDescription: String
    @Environment(\.graphiteFocusColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: GraphiteFocusPresentation.Space.primitive) {
            // The label does not borrow attention color: activity is represented
            // by ProgressView and its accessible value.
            GraphiteFocusStatusContent(meaning: .informational, text: title)
            if let value {
                ProgressView(value: max(0, min(1, value)))
                    .tint(Color(nsColor: colors.accent))
                    .accessibilityValue(valueDescription)
            } else {
                ProgressView()
                    .tint(Color(nsColor: colors.accent))
                    .accessibilityValue(valueDescription)
            }
            Text(valueDescription)
                .font(GraphiteFocusSwiftUI.metadataFont)
                .foregroundStyle(Color(nsColor: colors.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(valueDescription)
    }
}
