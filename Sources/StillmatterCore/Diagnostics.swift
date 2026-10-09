import Foundation

public enum DiagnosticStatus: String, Codable, Equatable {
    case granted
    case missing
    case unavailable
    case notConfigured
    case unknown

    public var isAvailable: Bool {
        switch self {
        case .granted:
            return true
        case .missing, .unavailable, .notConfigured, .unknown:
            return false
        }
    }
}

public struct DiagnosticItem: Codable, Equatable {
    public var id: String
    public var title: String
    public var status: DiagnosticStatus
    public var explanation: String
    public var affectedFeatures: [String]
    public var actionTitle: String?

    public init(
        id: String,
        title: String,
        status: DiagnosticStatus,
        explanation: String,
        affectedFeatures: [String] = [],
        actionTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.explanation = explanation
        self.affectedFeatures = affectedFeatures
        self.actionTitle = actionTitle
    }
}

public struct DiagnosticsSnapshot: Codable, Equatable {
    public var permissions: [DiagnosticItem]
    public var components: [DiagnosticItem]

    public init(permissions: [DiagnosticItem] = [], components: [DiagnosticItem] = []) {
        self.permissions = permissions
        self.components = components
    }

    public var missingFeatureSummary: String {
        let affected = (permissions + components)
            .filter { !$0.status.isAvailable }
            .flatMap { $0.affectedFeatures }

        if affected.isEmpty {
            return "All configured MVP features are available."
        }

        let unique = Array(Set(affected)).sorted()
        return "Unavailable until configured: \(unique.joined(separator: ", "))."
    }
}
