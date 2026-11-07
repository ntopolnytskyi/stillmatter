import Foundation

/// Reuses the same durable processing intent after an interrupted normal stop or startup recovery.
/// Capture session IDs are unique within the Job database; workspace ownership is checked before reuse.
public enum CaptureProcessingHandoff {
    public static func existing(sessionID: String, meetingRelativePath: String,
                                workspaceRootURL: URL, jobStore: JobStore) throws -> JobRecord? {
        let owner = workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath().path
        return try jobStore.jobs().first {
            $0.manifest.type == MeetingWorkflowJob.type &&
            $0.manifest.metadata["capture_session_id"] == sessionID &&
            $0.manifest.workspaceOwner == owner &&
            $0.manifest.sourceArtifacts.contains {
                $0.role == "meeting-doorway" && $0.relativePath == meetingRelativePath
            }
        }
    }

    public static func enqueueOnce(manifest: JobManifest, sessionID: String,
                                   meetingRelativePath: String, workspaceRootURL: URL,
                                   jobStore: JobStore) throws -> JobRecord {
        if let existing = try existing(sessionID: sessionID, meetingRelativePath: meetingRelativePath,
                                       workspaceRootURL: workspaceRootURL, jobStore: jobStore) {
            return existing
        }
        // A stable ID closes the race between two JobStore connections after the scan above.
        let id = "capture-workflow:\(sessionID)"
        do {
            return try jobStore.enqueue(id: id, manifest: manifest.owned(by: workspaceRootURL))
        } catch JobsError.duplicateJob {
            guard let existing = try existing(sessionID: sessionID, meetingRelativePath: meetingRelativePath,
                                              workspaceRootURL: workspaceRootURL, jobStore: jobStore) else { throw JobsError.duplicateJob(id) }
            return existing
        }
    }
}
