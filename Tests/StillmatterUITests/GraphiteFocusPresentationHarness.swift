import AppKit
import SwiftUI

@main
struct GraphiteFocusPresentationHarness {
    static func main() {
        _ = NSApplication.shared

        let normal = GraphiteFocusEnvironment(
            increasedContrast: false,
            reducedTransparency: false,
            reducedMotion: false,
            activeWindow: true
        )
        let variants = [
            normal,
            GraphiteFocusEnvironment(increasedContrast: true, reducedTransparency: false, reducedMotion: false, activeWindow: true),
            GraphiteFocusEnvironment(increasedContrast: false, reducedTransparency: true, reducedMotion: false, activeWindow: true),
            GraphiteFocusEnvironment(increasedContrast: false, reducedTransparency: false, reducedMotion: true, activeWindow: true),
            GraphiteFocusEnvironment(increasedContrast: false, reducedTransparency: false, reducedMotion: false, activeWindow: false)
        ]

        variants.forEach(validateFixture)

        let defaultColors = GraphiteFocusPresentation.Colors(environment: variants[0])
        require(rgba(GraphiteFocusSwiftUI.colors.accent) == rgba(GraphiteFocusPresentation.swiftUIColors().accent),
                "SwiftUI and AppKit must resolve the same accent")
        require(GraphiteFocusSwiftUI.sectionHeading == Font(GraphiteFocusPresentation.Typography.sectionHeading),
                "SwiftUI must use the AppKit typography role")
        let contrastColors = GraphiteFocusPresentation.Colors(environment: variants[1])
        let opaqueColors = GraphiteFocusPresentation.Colors(environment: variants[2])
        let inactiveColors = GraphiteFocusPresentation.Colors(environment: variants[4])

        require(alpha(contrastColors.structuralStroke) > alpha(defaultColors.structuralStroke), "Increased Contrast must strengthen structural strokes")
        require(
            contrastRatio(contrastColors.textSecondary, contrastColors.surfaceBase)
                > contrastRatio(defaultColors.textSecondary, defaultColors.surfaceBase),
            "Increased Contrast must strengthen secondary text separation"
        )
        require(
            contrastRatio(contrastColors.textMetadata, contrastColors.surfaceBase)
                > contrastRatio(defaultColors.textMetadata, defaultColors.surfaceBase),
            "Increased Contrast must strengthen metadata text separation"
        )
        require(alpha(defaultColors.surfaceTransient) < 1, "The normal transient surface should retain its restrained transparency")
        require(alpha(opaqueColors.surfaceTransient) == 1, "Reduce Transparency must use an opaque transient surface")
        require(alpha(inactiveColors.textPrimary) < alpha(defaultColors.textPrimary), "Inactive windows must de-emphasize chrome without changing roles")
        require(GraphiteFocusPresentation.Motion.local(variants[3]) == 0, "Reduce Motion must remove custom local motion")
        require(GraphiteFocusPresentation.Motion.region(variants[3]) == 0, "Reduce Motion must remove custom region motion")
    }

    private static func validateFixture(_ environment: GraphiteFocusEnvironment) {
        let colors = GraphiteFocusPresentation.Colors(environment: environment)
        let proofSurface = NSStackView()
        proofSurface.orientation = .vertical
        proofSurface.spacing = GraphiteFocusPresentation.Space.compact
        proofSurface.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        proofSurface.wantsLayer = true
        proofSurface.layer?.backgroundColor = colors.surfacePanel.cgColor
        GraphiteFocusPresentation.applyDarkAppearance(to: proofSurface)

        let labels = zip(
            GraphiteFocusStatusMeaning.allCases,
            ["Ready", "Recording", "Failed", "Index available"]
        ).map { meaning, text -> GraphiteFocusStatusLabel in
            let label = GraphiteFocusStatusLabel()
            label.setStatus(text, meaning: meaning, colors: colors)
            proofSurface.addArrangedSubview(label)
            return label
        }
        proofSurface.layoutSubtreeIfNeeded()

        require(proofSurface.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua, "Proof surface must use dark appearance")
        require(Set(labels.map(\.stringValue)).count == 4, "Every status needs distinct symbol and text meaning")
        require(Set(labels.map { rgba($0.textColor) }).count == 4, "Status semantic colors must remain distinct")
        require(labels.allSatisfy { !$0.statusText.isEmpty && $0.stringValue.contains($0.statusText) }, "Status meaning cannot rely on color")

        let semanticLabels = GraphiteFocusSemanticState.allCases.map { state -> GraphiteFocusStatusLabel in
            let label = GraphiteFocusStatusLabel()
            label.setState(state, colors: colors)
            proofSurface.addArrangedSubview(label)
            return label
        }
        require(semanticLabels.allSatisfy { !$0.statusText.isEmpty && !$0.stringValue.isEmpty }, "Every representative state must expose text and a non-color cue")
        require(rgba(GraphiteFocusSemanticState.readyCompleted.color(in: colors)) != rgba(colors.accent), "Ready/completed must not use accent outside bounded Meetings exception")
        require(rgba(GraphiteFocusSemanticState.selectedCurrent.color(in: colors)) != rgba(GraphiteFocusSemanticState.readyCompleted.color(in: colors)), "Selection must remain visually separate from status")

        let notice = GraphiteFocusInlineNoticeView()
        notice.configure(title: "Failed", detail: "Retry processing from the Jobs Inbox.", state: .failed, colors: colors)
        proofSurface.addArrangedSubview(notice)
        require(notice.accessibilityLabel()?.contains("Retry processing") == true, "Inline notices must expose actionable failure text")

        let progress = GraphiteFocusProgressStatusView()
        progress.configure(title: "Transcribing", value: 0.5, valueDescription: "50 percent complete", colors: colors)
        proofSurface.addArrangedSubview(progress)
        require(progress.accessibilityValue() == "50 percent complete", "Progress must expose a textual or numeric value")

        let button = NSButton(title: "Continue", target: nil, action: nil)
        button.bezelColor = colors.accent
        proofSurface.addArrangedSubview(button)
        require(button.focusRingType != .none, "Native control focus rings must remain system-owned")
        require(!GraphiteFocusStatusMeaning.allCases.map { rgba($0.color(in: colors)) }.contains(rgba(colors.accent)), "Accent must remain distinct from semantic status meanings")
    }

    private static func alpha(_ color: NSColor) -> CGFloat {
        color.usingColorSpace(.sRGB)?.alphaComponent ?? color.alphaComponent
    }

    private static func rgba(_ color: NSColor?) -> String {
        guard let color = color?.usingColorSpace(.sRGB) else { return "missing" }
        return "\(color.redComponent),\(color.greenComponent),\(color.blueComponent),\(color.alphaComponent)"
    }

    private static func contrastRatio(_ foreground: NSColor, _ background: NSColor) -> CGFloat {
        let lighter = max(relativeLuminance(foreground), relativeLuminance(background))
        let darker = min(relativeLuminance(foreground), relativeLuminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
