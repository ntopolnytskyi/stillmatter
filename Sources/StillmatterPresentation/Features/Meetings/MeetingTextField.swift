import Foundation

public enum MeetingTextField: Equatable {
    case notes
    case summary

    public var title: String { self == .summary ? "Summary" : "My Notes" }

    func displayedText(_ text: String) -> String {
        self == .notes ? text.trimmingCharacters(in: .newlines) : text
    }
}

