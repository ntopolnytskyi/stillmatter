import Foundation
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Completes a displayed item only after checking workspace ownership and current file content.
struct TodoCompletion {
    let appSupportRoot: URL
    let workspaceRoot: () -> URL?

    func complete(_ item: TodoItem, displayedRoot: URL?) throws -> TodoTaskViews {
        guard let root = workspaceRoot(), let displayedRoot,
              root.standardizedFileURL.resolvingSymlinksInPath() == displayedRoot.standardizedFileURL.resolvingSymlinksInPath() else {
            throw TodoItemMutationError.staleCanonicalItem(item.id)
        }
        let vault = WorkspaceVault(workspaceRootURL: root, appSupportRootURL: appSupportRoot)
        let queue = try vault.readMarkdown(relativePath: TodoItemIndex.mainTodoRelativePath)
        let current = try TodoItemIndex(workspaceRootURL: root).loadAllItems()
        guard let match = current.first(where: { $0.id == item.id }),
              match.rawText == item.rawText, match.status == item.status, match.isFromMainTodoFile,
              match.status == .open || match.status == .blocked else {
            throw TodoItemMutationError.staleCanonicalItem(item.id)
        }
        _ = try TodoItemMutator(vault: vault).updateStatus(item: match, status: .done, expectedVersion: queue.version)
        return try TodoItemIndex(workspaceRootURL: root).loadTaskViews(today: TodoItemMutator.systemToday())
    }
}
