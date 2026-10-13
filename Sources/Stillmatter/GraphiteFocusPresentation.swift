import AppKit
import SwiftUI

/// Central semantic presentation roles for the Graphite Focus contract.
/// Feature views consume these roles instead of choosing visual literals.
struct GraphiteFocusEnvironment: Equatable {
    var increasedContrast: Bool
    var reducedTransparency: Bool
    var reducedMotion: Bool
    var activeWindow: Bool

    static func system(window: NSWindow?) -> GraphiteFocusEnvironment {
        let workspace = NSWorkspace.shared
        return GraphiteFocusEnvironment(
            increasedContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            reducedTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            reducedMotion: workspace.accessibilityDisplayShouldReduceMotion,
            activeWindow: window?.isKeyWindow ?? true
        )
    }
}

enum GraphiteFocusPresentation {
    enum Space {
        static let flush: CGFloat = 0 // Divider-led collections have no inter-row gap.
        static let primitive: CGFloat = 4
        static let compact: CGFloat = 8
        static let dense: CGFloat = 12
        static let panel: CGFloat = 16
        static let page: CGFloat = 24
        static let large: CGFloat = 32
    }

    enum Radius {
        static let compact: CGFloat = 6
        static let control: CGFloat = 10
        static let panel: CGFloat = 14
        static let transient: CGFloat = 18
    }

    enum Stroke {
        static let width: CGFloat = 1
    }

    enum Motion {
        static func local(_ environment: GraphiteFocusEnvironment) -> TimeInterval {
            environment.reducedMotion ? 0 : 0.15
        }

        static func region(_ environment: GraphiteFocusEnvironment) -> TimeInterval {
            environment.reducedMotion ? 0 : 0.21
        }
    }

    enum Typography {
        static let pageTitle = NSFont.boldSystemFont(ofSize: 24)
        static let sectionHeading = NSFont.systemFont(ofSize: 16, weight: .semibold)
        static let body = NSFont.systemFont(ofSize: 14)
        static let rowTitle = NSFont.systemFont(ofSize: 14, weight: .medium)
        static let activeTranscriptSegment = NSFont.boldSystemFont(ofSize: 14)
        static let control = NSFont.systemFont(ofSize: 13, weight: .medium)
        static let metadata = NSFont.systemFont(ofSize: 12)
        static let caption = NSFont.systemFont(ofSize: 10, weight: .semibold)
        static let numeric = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        static let longForm = NSFont.systemFont(ofSize: 14)
    }

    struct Colors {
        let surfaceBase: NSColor
        let surfaceChrome: NSColor
        let surfacePanel: NSColor
        let surfaceRaised: NSColor
        let surfaceSelectionNeutral: NSColor
        let surfaceTransient: NSColor
        let textPrimary: NSColor
        let textSecondary: NSColor
        let textMetadata: NSColor
        let textDisabled: NSColor
        let accent: NSColor
        let accentHover: NSColor
        let accentPressed: NSColor
        let accentOn: NSColor
        let success: NSColor
        let attention: NSColor
        let destructive: NSColor
        let informational: NSColor
        let structuralStroke: NSColor

        init(environment: GraphiteFocusEnvironment) {
            surfaceBase = Self.color(0x1C1D1F)
            surfaceChrome = Self.color(0x242628)
            surfacePanel = Self.color(0x2D3032)
            surfaceRaised = Self.color(0x3A3D40)
            surfaceSelectionNeutral = Self.strengthen(
                Self.color(0x35343D),
                by: 0.08,
                when: environment.increasedContrast
            )
            surfaceTransient = Self.color(0x111415, alpha: environment.reducedTransparency ? 1 : 0.96)

            let inactiveTextAlpha: CGFloat = environment.activeWindow ? 1 : 0.84
            textPrimary = Self.color(0xF4F2ED, alpha: inactiveTextAlpha)
            textSecondary = Self.strengthen(
                Self.color(0xD0D1CC, alpha: environment.activeWindow ? 1 : 0.88),
                by: 0.12,
                when: environment.increasedContrast
            )
            textMetadata = Self.strengthen(
                Self.color(0xA4A8A5, alpha: environment.activeWindow ? 1 : 0.9),
                by: 0.18,
                when: environment.increasedContrast
            )
            textDisabled = Self.strengthen(
                Self.color(0x7F8582),
                by: 0.18,
                when: environment.increasedContrast
            )

            accent = Self.color(0xB58AE8)
            accentHover = Self.color(0xC9A5F2)
            accentPressed = Self.color(0x9770C7)
            accentOn = Self.color(0x1C1526)
            success = Self.color(0x6BD18F)
            attention = Self.color(0xEFBD61)
            destructive = Self.color(0xFF7C74)
            informational = Self.color(0x7BAEEA)
            structuralStroke = NSColor.white.withAlphaComponent(environment.increasedContrast ? 0.20 : 0.12)
        }

        private static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
            NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
                green: CGFloat((rgb >> 8) & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255,
                alpha: alpha
            )
        }

        private static func strengthen(_ color: NSColor, by fraction: CGFloat, when enabled: Bool) -> NSColor {
            guard enabled else { return color }
            let strengthened = color.blended(withFraction: fraction, of: .white) ?? color
            return strengthened.withAlphaComponent(color.alphaComponent)
        }
    }

    /// SwiftUI and AppKit resolve the same roles, including accessibility variants.
    static func swiftUIColors(window: NSWindow? = nil) -> Colors {
        Colors(environment: .system(window: window))
    }

    static func applyDarkAppearance(to view: NSView) {
        view.appearance = NSAppearance(named: .darkAqua)
    }
}

enum GraphiteFocusStatusMeaning: CaseIterable {
    case success
    case attention
    case destructive
    case informational

    var symbol: String {
        switch self {
        case .success: return "✓"
        case .attention: return "●"
        case .destructive: return "!"
        case .informational: return "ⓘ"
        }
    }

    func color(in colors: GraphiteFocusPresentation.Colors) -> NSColor {
        switch self {
        case .success: return colors.success
        case .attention: return colors.attention
        case .destructive: return colors.destructive
        case .informational: return colors.informational
        }
    }
}

enum GraphiteFocusSemanticState: CaseIterable {
    case selectedCurrent
    case readyCompleted
    case needsAttentionLive
    case failed
    case loadingProcessing
    case unavailable
    case disabled
    case destructiveAction
    case primaryAction

    var defaultText: String {
        switch self {
        case .selectedCurrent: return "Selected"
        case .readyCompleted: return "Ready"
        case .needsAttentionLive: return "Needs attention"
        case .failed: return "Failed"
        case .loadingProcessing: return "Processing"
        case .unavailable: return "Unavailable"
        case .disabled: return "Disabled"
        case .destructiveAction: return "Destructive action"
        case .primaryAction: return "Primary action"
        }
    }

    var symbol: String {
        switch self {
        case .selectedCurrent: return "◆"
        case .readyCompleted: return GraphiteFocusStatusMeaning.success.symbol
        case .needsAttentionLive: return GraphiteFocusStatusMeaning.attention.symbol
        case .failed: return GraphiteFocusStatusMeaning.destructive.symbol
        case .loadingProcessing: return "…"
        case .unavailable: return "○"
        case .disabled: return "–"
        case .destructiveAction: return GraphiteFocusStatusMeaning.destructive.symbol
        case .primaryAction: return "↵"
        }
    }

    var statusMeaning: GraphiteFocusStatusMeaning? {
        switch self {
        case .readyCompleted: return .success
        case .needsAttentionLive, .loadingProcessing: return .attention
        case .failed, .destructiveAction: return .destructive
        case .unavailable: return .informational
        case .selectedCurrent, .disabled, .primaryAction: return nil
        }
    }

    func color(in colors: GraphiteFocusPresentation.Colors) -> NSColor {
        switch self {
        case .selectedCurrent: return colors.textPrimary
        case .primaryAction: return colors.accent
        case .disabled: return colors.textDisabled
        case .readyCompleted, .needsAttentionLive, .failed, .loadingProcessing, .unavailable, .destructiveAction:
            return statusMeaning?.color(in: colors) ?? colors.textSecondary
        }
    }
}

/// A status always includes a textual state and a non-color symbol cue.
final class GraphiteFocusStatusLabel: NSTextField {
    private(set) var meaning: GraphiteFocusStatusMeaning = .informational
    private(set) var semanticState: GraphiteFocusSemanticState?
    private(set) var statusText = ""

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        font = GraphiteFocusPresentation.Typography.metadata
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func setState(
        _ state: GraphiteFocusSemanticState,
        text: String? = nil,
        colors: GraphiteFocusPresentation.Colors
    ) {
        semanticState = state
        if let meaning = state.statusMeaning { self.meaning = meaning }
        let resolvedText = text ?? state.defaultText
        statusText = resolvedText
        stringValue = "\(state.symbol) \(resolvedText)"
        textColor = state.color(in: colors)
        setAccessibilityLabel(resolvedText)
        setAccessibilityValue(resolvedText)
    }

    func setStatus(
        _ text: String,
        meaning: GraphiteFocusStatusMeaning,
        colors: GraphiteFocusPresentation.Colors
    ) {
        semanticState = nil
        self.meaning = meaning
        statusText = text
        stringValue = "\(meaning.symbol) \(text)"
        textColor = meaning.color(in: colors)
        setAccessibilityLabel(text)
        setAccessibilityValue(text)
    }
}

final class GraphiteFocusInlineNoticeView: NSStackView {
    let statusLabel = GraphiteFocusStatusLabel()
    let detailLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = GraphiteFocusPresentation.Space.primitive
        detailLabel.font = GraphiteFocusPresentation.Typography.body
        detailLabel.maximumNumberOfLines = 0
        addArrangedSubview(statusLabel)
        addArrangedSubview(detailLabel)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func configure(
        title: String,
        detail: String,
        state: GraphiteFocusSemanticState,
        colors: GraphiteFocusPresentation.Colors
    ) {
        statusLabel.setState(state, text: title, colors: colors)
        detailLabel.stringValue = detail
        detailLabel.textColor = colors.textSecondary
        setAccessibilityLabel("\(title). \(detail)")
    }
}

final class GraphiteFocusProgressStatusView: NSStackView {
    let statusLabel = GraphiteFocusStatusLabel()
    let progressIndicator = NSProgressIndicator()
    let valueLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = GraphiteFocusPresentation.Space.primitive
        progressIndicator.isIndeterminate = true
        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        valueLabel.font = GraphiteFocusPresentation.Typography.metadata
        addArrangedSubview(statusLabel)
        addArrangedSubview(progressIndicator)
        addArrangedSubview(valueLabel)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func configure(
        title: String,
        value: Double?,
        valueDescription: String,
        colors: GraphiteFocusPresentation.Colors
    ) {
        statusLabel.setState(.loadingProcessing, text: title, colors: colors)
        progressIndicator.isIndeterminate = value == nil
        if let value {
            progressIndicator.minValue = 0
            progressIndicator.maxValue = 1
            progressIndicator.doubleValue = max(0, min(1, value))
        }
        valueLabel.stringValue = valueDescription
        valueLabel.textColor = colors.textSecondary
        setAccessibilityLabel(title)
        setAccessibilityValue(valueDescription)
    }
}
