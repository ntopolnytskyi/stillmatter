import Foundation
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Serializes builds against the single derived search database across settings changes.
actor SearchIndexBuilder {
    func build(databaseURL: URL, rootURL: URL, excludedPatterns: [String], recovering: Bool) throws -> SearchIndex {
        let index = recovering
            ? try SearchIndex.recoveringRebuild(databaseURL: databaseURL, workspaceRootURL: rootURL, excludedPatterns: excludedPatterns)
            : try SearchIndex(databaseURL: databaseURL, workspaceRootURL: rootURL, excludedPatterns: excludedPatterns)
        if !recovering { try index.startupScan() }
        return index
    }
}
