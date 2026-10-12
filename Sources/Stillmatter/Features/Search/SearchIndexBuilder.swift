import Foundation
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Serializes builds against the single derived search database across settings changes.
actor SearchIndexBuilder {
    func build(databaseURL: URL, rootURL: URL, excludedPatterns: [String], recovering: Bool) throws -> SearchIndex {
        // A superseded build waiting behind an active scan must never start another scan.
        try Task.checkCancellation()
        let index = recovering
            ? try SearchIndex.recoveringRebuild(databaseURL: databaseURL, workspaceRootURL: rootURL, excludedPatterns: excludedPatterns)
            : try SearchIndex(databaseURL: databaseURL, workspaceRootURL: rootURL, excludedPatterns: excludedPatterns)
        try Task.checkCancellation()
        if !recovering { try index.startupScan() }
        try Task.checkCancellation()
        return index
    }
}
