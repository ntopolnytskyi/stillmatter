import Foundation

/// Decides which Adaptive Shell regions can remain useful at a given width.
/// User preferences are inputs, but automatic collapse never mutates them.
public struct AdaptiveShellLayout: Equatable {
    /// Fixed width of the global icon rail; not a resizable source-list column.
    public static let sidebarWidth: CGFloat = 64

    public enum DetailMode: Equatable {
        case detailOnly
        case listAndDetail
        case listOnly
    }

    public let showsSidebar: Bool
    public let showsInspector: Bool
    public let detailMode: DetailMode

    public var isNarrowNavigation: Bool { detailMode == .listOnly }

    public init(
        availableWidth: CGFloat,
        hasContentList: Bool,
        hasInspector: Bool,
        prefersSidebar: Bool,
        prefersInspector: Bool
    ) {
        let divider: CGFloat = 1
        let sidebar = Self.sidebarWidth
        let contentList: CGFloat = hasContentList ? 260 : 0
        let detail: CGFloat = 480
        let inspector: CGFloat = hasInspector ? 280 : 0

        let preferredSidebarWidth = prefersSidebar ? sidebar + divider : 0
        let listWidth = hasContentList ? contentList + divider : 0
        let inspectorWidth = hasInspector && prefersInspector ? inspector + divider : 0

        // Collapse the inspector first; retain the narrow navigation rail alongside the list.
        let canShowInspector = inspectorWidth > 0
            && availableWidth >= preferredSidebarWidth + listWidth + detail + inspectorWidth
        showsInspector = canShowInspector

        let widthWithoutInspector = availableWidth - (canShowInspector ? inspectorWidth : 0)
        let canShowSidebar = prefersSidebar
            && widthWithoutInspector >= sidebar + divider + (hasContentList ? contentList : detail)
        showsSidebar = canShowSidebar

        let mainWidth = widthWithoutInspector - (canShowSidebar ? sidebar + divider : 0)
        if !hasContentList {
            detailMode = .detailOnly
        } else if mainWidth >= contentList + divider + detail {
            detailMode = .listAndDetail
        } else {
            detailMode = .listOnly
        }
    }
}
