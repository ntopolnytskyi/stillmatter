import Foundation

public enum ShellTab: String, CaseIterable, Equatable {
    case today = "Today"
    case recording = "Recording"
    case meetings = "Meetings"
    case tasks = "Tasks"
    case projectsActivities = "Activities"
    case reports = "Reports"
    case askAI = "Ask AI"
    case settings = "Settings"
}

public struct ShellState: Equatable {
    public var selectedTab: ShellTab
    public var searchText: String

    public init(
        selectedTab: ShellTab = .today,
        searchText: String = ""
    ) {
        self.selectedTab = selectedTab
        self.searchText = searchText
    }

    public mutating func select(_ tab: ShellTab) {
        selectedTab = tab
    }
}
