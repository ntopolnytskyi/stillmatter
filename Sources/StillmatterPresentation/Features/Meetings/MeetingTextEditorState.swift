import Foundation

/// A projection of the active edit. Canonical text and its version remain in MeetingTextDraft.
public struct MeetingTextEditorState: Equatable, Identifiable {
    public let id: UUID
    public let field: MeetingTextField
    public let meetingTitle: String
    public internal(set) var text: String
    enum Activity { case editing, saving, reloading }
    var activity = Activity.editing
    public var isBusy: Bool { activity != .editing }
    public internal(set) var error: String?
    public internal(set) var canReload = false
}
