import SwiftUI

/// Shared semantic presentation for views embedded in AppKit's meeting detail.
/// Native buttons retain focus rings, keyboard activation and disabled behavior.
enum GraphiteFocusSwiftUI {
    static var colors: GraphiteFocusPresentation.Colors { GraphiteFocusPresentation.swiftUIColors() }
    static var primary: Color { Color(nsColor: colors.textPrimary) }
    static var secondary: Color { Color(nsColor: colors.textSecondary) }
    static var metadata: Color { Color(nsColor: colors.textMetadata) }
    static var accent: Color { Color(nsColor: colors.accent) }
    static var stroke: Color { Color(nsColor: colors.structuralStroke) }

    static func font(_ role: NSFont) -> Font { Font(role) }

    static var pageTitle: Font { font(GraphiteFocusPresentation.Typography.pageTitle) }
    static var sectionHeading: Font { font(GraphiteFocusPresentation.Typography.sectionHeading) }
    static var body: Font { font(GraphiteFocusPresentation.Typography.body) }
    static var rowTitle: Font { font(GraphiteFocusPresentation.Typography.rowTitle) }
    static var control: Font { font(GraphiteFocusPresentation.Typography.control) }
    static var metadataFont: Font { font(GraphiteFocusPresentation.Typography.metadata) }
    static var caption: Font { font(GraphiteFocusPresentation.Typography.caption) }
    static var numeric: Font { font(GraphiteFocusPresentation.Typography.numeric) }
}

private struct GraphiteFocusPanel: ViewModifier {
    @State private var revision = 0

    func body(content: Content) -> some View {
        let colors = GraphiteFocusSwiftUI.colors
        _ = revision // Invalidate semantic colors when macOS accessibility options change.
        return content
            .padding(GraphiteFocusPresentation.Space.panel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: colors.surfacePanel))
            .clipShape(RoundedRectangle(cornerRadius: GraphiteFocusPresentation.Radius.panel))
            .overlay(RoundedRectangle(cornerRadius: GraphiteFocusPresentation.Radius.panel)
                .strokeBorder(Color(nsColor: colors.structuralStroke), lineWidth: GraphiteFocusPresentation.Stroke.width))
            .foregroundStyle(Color(nsColor: colors.textPrimary))
            .environment(\.colorScheme, .dark)
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
                revision &+= 1
            }
    }
}

extension View {
    func graphitePanel() -> some View { modifier(GraphiteFocusPanel()) }
}
