import AppKit
import StillmatterPresentation

#if DEBUG
extension MeetingManagementView {
    func validateBrowserFilterPresentationFixture() {
        let savedQuery = queryField.stringValue
        let savedQueue = selectedQueue
        defer {
            queryField.stringValue = savedQuery
            selectedQueue = savedQueue
            updateQueueButtons()
            updateFilterStatus(visibleCount: browserFixtureRowCount)
        }
        precondition(queryField.placeholderString == "Filter meetings", "Meeting browser field must be labeled as a row filter")
        precondition(queryField.accessibilityLabel() as? String == "Filter meetings", "Meeting browser filter must have a distinct accessible name")
        queryField.stringValue = "roadmap"
        selectedQueue = .ready
        updateQueueButtons()
        updateFilterStatus(visibleCount: 2)
        precondition(filterStatus.stringValue.contains("Queue: Ready") && filterStatus.stringValue.contains("Text: “roadmap”"),
                     "Meeting browser must show active list filter context")
    }

}
#endif
