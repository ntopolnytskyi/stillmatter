import Foundation

/// Reads the authoritative member of the canonical Transcript pair without
/// migrating a Meeting or changing either representation or its manifest.
struct SearchTranscriptSource {
    let relativePath: String
    let json: String

    private struct Manifest: Decodable {
        let version: Int
        let transcriptBaseHash: String?
    }

    static func read(relativePath: String, workspaceRoot: URL) throws -> SearchTranscriptSource? {
        guard relativePath.hasPrefix("Meetings/"),
              ["transcript.json", "transcript.txt"].contains((relativePath as NSString).lastPathComponent) else { return nil }
        let directory = (relativePath as NSString).deletingLastPathComponent
        func read(_ name: String) throws -> Data? {
            let url = workspaceRoot.appendingPathComponent(directory).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            guard url.resolvingSymlinksInPath().path.hasPrefix(workspaceRoot.path + "/") else {
                throw MeetingManagementError.malformed("Transcript companion escapes this workspace: \(directory)/\(name).")
            }
            return try Data(contentsOf: url)
        }
        let text = try read("transcript.txt")
        let json = try read("transcript.json")
        let manifestData = try read("meeting-artifacts.json")
        // Unmigrated JSON-only documents retain the existing legacy indexing path.
        guard text != nil || manifestData != nil else { return nil }
        let manifest = try manifestData.map { try JSONDecoder().decode(Manifest.self, from: $0) }
        guard manifest == nil || manifest?.version == 1 else {
            throw MeetingManagementError.malformed("Unsupported Transcript manifest: \(directory)/meeting-artifacts.json.")
        }
        guard let pair = try MeetingTranscriptCodec.reconcile(baseHash: manifest?.transcriptBaseHash,
            text: text, json: json, path: directory + "/transcript") else { return nil }
        let document = try MeetingTranscriptCodec.document(pair.json, path: relativePath)
        guard document.meetingRelativePath == directory + "/meeting.md" else {
            throw MeetingManagementError.malformed("Transcript identity does not match its owning Meeting: \(directory).")
        }
        let fromJSON = try json.map { try MeetingTranscriptCodec.canonicalJSON($0) == pair.json } ?? false
        return SearchTranscriptSource(relativePath: directory + (fromJSON ? "/transcript.json" : "/transcript.txt"),
            json: String(decoding: pair.json, as: UTF8.self))
    }
}
