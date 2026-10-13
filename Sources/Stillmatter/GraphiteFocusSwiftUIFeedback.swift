import SwiftUI

struct GraphiteFocusStatusView: View {
    let state: GraphiteFocusSemanticState
    let text: String

    init(_ state: GraphiteFocusSemanticState, text: String? = nil) {
        self.state = state
        self.text = text ?? state.defaultText
    }

    var body: some View {
        let colors = GraphiteFocusSwiftUI.colors
        Text("\(state.symbol) \(text)")
            .font(GraphiteFocusSwiftUI.metadataFont)
            .foregroundStyle(Color(nsColor: state.color(in: colors)))
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityLabel(text)
            .accessibilityValue(text)
    }
}

struct GraphiteFocusInlineNotice: View {
    let title: String
    let detail: String
    let state: GraphiteFocusSemanticState

    var body: some View {
        VStack(alignment: .leading, spacing: GraphiteFocusPresentation.Space.primitive) {
            GraphiteFocusStatusView(state, text: title)
            Text(detail)
                .font(GraphiteFocusSwiftUI.body)
                .foregroundStyle(GraphiteFocusSwiftUI.secondary)
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
        VStack(alignment: .leading, spacing: GraphiteFocusPresentation.Space.primitive) {
            GraphiteFocusStatusView(.loadingProcessing, text: title)
            if let value {
                ProgressView(value: max(0, min(1, value)))
                    .tint(GraphiteFocusSwiftUI.accent)
                    .accessibilityValue(valueDescription)
            } else {
                ProgressView()
                    .tint(GraphiteFocusSwiftUI.accent)
                    .accessibilityValue(valueDescription)
            }
            Text(valueDescription)
                .font(GraphiteFocusSwiftUI.metadataFont)
                .foregroundStyle(GraphiteFocusSwiftUI.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(valueDescription)
    }
}
