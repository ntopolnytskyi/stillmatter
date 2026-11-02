import Foundation
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Legacy task IDs contain line numbers; only durable UUIDs survive a reorder.
enum TodoSelection {
    static func resolve(_ selected: TodoItem, in items: [TodoItem]) -> TodoItem? {
        if UUID(uuidString: selected.id) != nil {
            return items.first { $0.id == selected.id }
        }
        return TodayTargetResolution.queue(selected, selectedOwner: "", owner: "",
            current: items.filter { $0.location.relativePath == selected.location.relativePath })
    }
}
