import AppKit
import SwiftUI

/// Observable semantic context owned by one SwiftUI hosting root/window.
/// It keeps Window Context and macOS display accessibility settings current.
final class GraphiteFocusSemanticContext: ObservableObject {
    @Published private(set) var environment = GraphiteFocusEnvironment.system(window: nil)

    private weak var window: NSWindow?
    private var displayObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []

    init() {
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    deinit {
        if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver) }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func attach(to window: NSWindow?) {
        guard self.window !== window else { return }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        self.window = window
        if let window {
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.refresh()
                })
            }
        }
        refresh()
    }

    var colors: GraphiteFocusPresentation.Colors {
        GraphiteFocusPresentation.Colors(environment: environment)
    }

    private func refresh() {
        environment = .system(window: window)
    }
}

private struct GraphiteFocusColorsKey: EnvironmentKey {
    static let defaultValue = GraphiteFocusPresentation.Colors(environment: .system(window: nil))
}

extension EnvironmentValues {
    var graphiteFocusColors: GraphiteFocusPresentation.Colors {
        get { self[GraphiteFocusColorsKey.self] }
        set { self[GraphiteFocusColorsKey.self] = newValue }
    }
}

private struct GraphiteFocusWindowReader: NSViewRepresentable {
    let attach: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowObservingView()
        view.onWindowChange = attach
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attach(nsView.window)
    }

    private final class WindowObservingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}

private final class GraphiteFocusSemanticContextStore {
    static let shared = GraphiteFocusSemanticContextStore()
    private let contexts = NSMapTable<NSWindow, GraphiteFocusSemanticContext>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )
    let unattached = GraphiteFocusSemanticContext()

    func context(for window: NSWindow?) -> GraphiteFocusSemanticContext {
        guard let window else { return unattached }
        if let existing = contexts.object(forKey: window) { return existing }
        let context = GraphiteFocusSemanticContext()
        context.attach(to: window)
        contexts.setObject(context, forKey: window)
        return context
    }
}

private struct GraphiteFocusSemanticContent<Content: View>: View {
    let content: Content
    @ObservedObject var context: GraphiteFocusSemanticContext

    var body: some View {
        content.environment(\.graphiteFocusColors, context.colors)
    }
}

private struct GraphiteFocusSemanticRoot: ViewModifier {
    @State private var hostingWindow: NSWindow?

    func body(content: Content) -> some View {
        GraphiteFocusSemanticContent(
            content: content,
            context: GraphiteFocusSemanticContextStore.shared.context(for: hostingWindow)
        )
        .background(GraphiteFocusWindowReader { window in
            if hostingWindow !== window { hostingWindow = window }
        })
    }
}

/// Shared semantic presentation for views embedded in AppKit's meeting detail.
/// Native buttons retain focus rings, keyboard activation and disabled behavior.
enum GraphiteFocusSwiftUI {
    static func contextForValidation(window: NSWindow) -> GraphiteFocusSemanticContext {
        GraphiteFocusSemanticContextStore.shared.context(for: window)
    }

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
    @Environment(\.graphiteFocusColors) private var colors

    func body(content: Content) -> some View {
        content
            .padding(GraphiteFocusPresentation.Space.panel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: colors.surfacePanel))
            .clipShape(RoundedRectangle(cornerRadius: GraphiteFocusPresentation.Radius.panel))
            .overlay(RoundedRectangle(cornerRadius: GraphiteFocusPresentation.Radius.panel)
                .strokeBorder(Color(nsColor: colors.structuralStroke), lineWidth: GraphiteFocusPresentation.Stroke.width))
            .foregroundStyle(Color(nsColor: colors.textPrimary))
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    /// Install once at each NSHostingView root so all descendants share one
    /// observable semantic context tied to that hosting window.
    func graphiteSemanticContext() -> some View { modifier(GraphiteFocusSemanticRoot()) }
    func graphitePanel() -> some View {
        modifier(GraphiteFocusPanel()).graphiteSemanticContext()
    }
}
