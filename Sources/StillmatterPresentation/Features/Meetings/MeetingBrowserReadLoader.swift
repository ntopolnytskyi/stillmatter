import StillmatterCore

/// Thin, injectable boundary around the real Meetings browser/detail reads.
public final class MeetingBrowserReadLoader {
    private let metrics: MeetingPresentationMetrics

    public init(metrics: MeetingPresentationMetrics) {
        self.metrics = metrics
    }

    public func browserRows(
        from service: MeetingManagementService,
        filters: MeetingBrowserFilters
    ) throws -> (visible: [MeetingBrowserRow], available: [MeetingBrowserRow]) {
        try metrics.measureBrowserReload { try service.browserRows(filters: filters) }
    }

    public func detail(
        for row: MeetingBrowserRow,
        from service: MeetingManagementService
    ) throws -> MeetingBrowserDetail {
        try metrics.measureMeetingRead { try service.detail(for: row) }
    }
}
