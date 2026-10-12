import Foundation
#if SWIFT_PACKAGE
import StillmatterCore
import StillmatterPresentation
#endif

/// Today owns its projection and the lifetime of its serial workspace read.
final class TodayWorkbenchLoader {
    private(set) var state: TodayWorkbenchView.State = .loading
    private let onChange: () -> Void
    private lazy var reader = WorkbenchReadLoader<TodayWorkbenchView.State>(label: "Stillmatter.Today.Read") { [weak self] value in
        self?.state = value
        self?.onChange()
    }

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func reload(rootURL: URL?, inbox: TasksInbox?,
                recording: String, jobs: String, calendarSelection: CalendarSourceSelection) {
        reader.reload {
            guard let inbox else { return .unavailable("The operational Inbox could not be opened.") }
            guard let rootURL else {
                return .unavailable("Choose a Stillmatter root to load Inbox, Queue and Meeting context.")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .unavailable("The configured Stillmatter root is not available. Choose an accessible workspace in Settings.")
            }
            let upcoming = CalendarMeetingProvider(calendarSelection: calendarSelection)
                .meetingsToday().map { TodayMeeting(title: $0.title, time: $0.time,
                    eventIdentifier: $0.eventIdentifier, calendarIdentifier: $0.calendarIdentifier,
                    eventStart: $0.eventStart) }
            do {
                return .loaded(try TodayDashboard(
                    workspaceRootURL: rootURL, inbox: inbox,
                    recordingStatus: { recording }, jobStatus: { jobs }, upcomingMeetings: { upcoming }
                ).load())
            } catch {
                return .failed(String(describing: error))
            }
        }
    }

    func reset() { reader.invalidate(); state = .loading }
    func stop() { reader.stop() }
}

/// Tasks owns its canonical Todo projection; filter, mode and selection stay in TodoLedgerView.
final class TodoLedgerLoader {
    private(set) var state: TodoLedgerView.State = .unavailable("Loading Tasks…")
    private let onChange: () -> Void
    private lazy var reader = WorkbenchReadLoader<TodoLedgerView.State>(label: "Stillmatter.Tasks.Read") { [weak self] value in
        self?.state = value
        self?.onChange()
    }

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func reload(rootURL: URL?) {
        reader.reload {
            guard let rootURL else {
                return .unavailable("Choose a Stillmatter root in Settings to read canonical Todo Items.")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .unavailable("The configured Stillmatter root is not available. Choose an accessible workspace in Settings.")
            }
            do {
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                return .loaded(try TodoItemIndex(workspaceRootURL: rootURL)
                    .loadTaskViews(today: formatter.string(from: Date())))
            } catch {
                return .failed(String(describing: error))
            }
        }
    }

    func reset() { reader.invalidate(); state = .unavailable("Loading Tasks…") }
    func stop() { reader.stop() }
}
