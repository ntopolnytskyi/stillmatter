import Foundation

/// Selects permitted authoritative text for Search. Both full scans and watcher
/// refreshes use the same companion, exclusion and symlink rules. Reads never migrate files.
struct SearchSources {
    struct Source {
        let relativePath: String
        let contents: String
        let isTranscript: Bool
    }

    struct Refresh {
        let paths: [String]
        let errorKey: String
    }

    let workspaceRootURL: URL
    let excludedPatterns: [String]

    private static let transcriptRepresentations = ["transcript.json", "transcript.txt", "transcript.vtt"]
    private static let canonicalCompanions = ["transcript.json", "transcript.txt", "meeting-artifacts.json"]

    func refresh(for relativePath: String) -> Refresh {
        let path = Self.normalize(relativePath)
        let directory = (path as NSString).deletingLastPathComponent
        let paired = Self.canonicalCompanions.contains((path as NSString).lastPathComponent)
        return Refresh(paths: paired ? Self.transcriptRepresentations.map { directory.isEmpty ? $0 : directory + "/" + $0 } : [path],
                       errorKey: paired ? directory + "/transcript" : path)
    }

    func read(_ relativePath: String) throws -> Source? {
        let fileURL = workspaceRootURL.appendingPathComponent(relativePath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, isIndexable(relativePath: relativePath) else { return nil }
        // Canonical representations are one artifact: an excluded companion must
        // never re-enter retrieval through its other representation or a symlink.
        if relativePath.hasPrefix("Meetings/"), ["transcript.json", "transcript.txt"].contains(fileURL.lastPathComponent) {
            let directory = (relativePath as NSString).deletingLastPathComponent
            let excludedCompanion = Self.canonicalCompanions.contains { name in
                let path = directory + "/" + name
                let url = workspaceRootURL.appendingPathComponent(path)
                return FileManager.default.fileExists(atPath: url.path) &&
                    isExcludedSource(relativePath: path, resolvedURL: url.resolvingSymlinksInPath())
            }
            if excludedCompanion { return nil }
        }
        if let source = try Transcript.read(relativePath: relativePath, workspaceRoot: workspaceRootURL) {
            return Source(relativePath: source.relativePath, contents: source.json, isTranscript: true)
        } else {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            guard let contents = String(data: data, encoding: .utf8) else { return nil }
            return Source(relativePath: relativePath, contents: contents, isTranscript: false)
        }
    }

    func paths() throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: workspaceRootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [String] = []
        for case let enumeratedURL as URL in enumerator {
            let url = enumeratedURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(workspaceRootURL.path + "/") else { continue }
            let relativePath = String(url.path.dropFirst(workspaceRootURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isDirectory == true && isExcluded(relativePath: relativePath, isDirectory: true, applyConfiguredPatterns: false) {
                enumerator.skipDescendants()
            } else if values.isRegularFile == true && isIndexable(relativePath: relativePath) {
                files.append(relativePath)
            }
        }
        return files.sorted()
    }

    private func isIndexable(relativePath: String) -> Bool {
        let resolved = workspaceRootURL.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(workspaceRootURL.path + "/") else { return false }
        let path = relativePath.lowercased()
        if path.hasSuffix("/transcript.vtt"),
           ["transcript.json", "transcript.txt"].contains(where: {
               FileManager.default.fileExists(atPath: resolved.deletingLastPathComponent().appendingPathComponent($0).path)
           }) { return false }
        if path.hasSuffix("/transcript.txt"),
           FileManager.default.fileExists(atPath: resolved.deletingLastPathComponent().appendingPathComponent("transcript.json").path) { return false }
        if path.hasPrefix("meetings/") {
            let allowed = ["meeting.md", "summary.md", "notes.md", "my-notes.md", "action-items.md", "decisions.md", "open-items.md", "transcript.json", "transcript.txt", "transcript.vtt", "recording.localref.json"]
            guard allowed.contains(resolved.lastPathComponent.lowercased()) else { return false }
        }
        let isLightweightMetadata = path.hasSuffix("/recording.localref.json") || path == "recording.localref.json"
        guard !isExcludedSource(relativePath: relativePath, resolvedURL: resolved,
            applyConfiguredPatterns: !isLightweightMetadata) else { return false }
        if path.hasPrefix("meetings/"), path.hasSuffix("/transcript.txt") { return true }
        if path.hasSuffix(".md") { return true }
        if path.hasSuffix("/transcript.vtt") || path == "transcript.vtt" { return true }
        if path.hasSuffix("/transcript.json") || path == "transcript.json" { return true }
        return isLightweightMetadata
    }

    private func isExcludedSource(relativePath: String, resolvedURL: URL, applyConfiguredPatterns: Bool = true) -> Bool {
        if isExcluded(relativePath: relativePath, isDirectory: false, applyConfiguredPatterns: applyConfiguredPatterns) { return true }
        guard resolvedURL.path.hasPrefix(workspaceRootURL.path + "/") else { return false }
        let actualPath = String(resolvedURL.path.dropFirst(workspaceRootURL.path.count + 1))
        return actualPath != relativePath && isExcluded(relativePath: actualPath, isDirectory: false,
            applyConfiguredPatterns: applyConfiguredPatterns)
    }

    private func isExcluded(relativePath: String, isDirectory: Bool, applyConfiguredPatterns: Bool = true) -> Bool {
        let normalized = Self.normalize(relativePath)
        let lowercased = normalized.lowercased()
        let components = lowercased.split(separator: "/").map(String.init)
        let noisyDirectories: Set<String> = ["voiceprofiles", "voice-profiles", "voice_profiles", "voices",".git", ".obsidian", "node_modules", "dist", "build", ".build", ".cache", ".tmp", "snapshots", "logs"]
        if components.contains(where: noisyDirectories.contains) { return true }
        if !isDirectory {
            let filename = components.last ?? ""
            let excludedExtensions: Set<String> = [
                "m4a", "mp3", "wav", "caf", "mp4", "mov", "webm",
                "png", "jpg", "jpeg", "heic", "gif", "pdf", "zip", "tar", "gz",
                "sqlite", "sqlite-wal", "sqlite-shm", "db", "log"
            ]
            if excludedExtensions.contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) { return true }
            if filename == ".ds_store" { return true }
        }
        return applyConfiguredPatterns && excludedPatterns.contains { Self.glob($0, matches: normalized, isDirectory: isDirectory) }
    }

    private static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func glob(_ pattern: String, matches path: String, isDirectory: Bool) -> Bool {
        let normalizedPattern = normalize(pattern)
        var expression = "^"
        var index = normalizedPattern.startIndex
        while index < normalizedPattern.endIndex {
            let character = normalizedPattern[index]
            if character == "*" {
                let next = normalizedPattern.index(after: index)
                if next < normalizedPattern.endIndex && normalizedPattern[next] == "*" {
                    expression += ".*"
                    index = normalizedPattern.index(after: next)
                } else {
                    expression += "[^/]*"
                    index = next
                }
            } else if character == "?" {
                expression += "[^/]"
                index = normalizedPattern.index(after: index)
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
                index = normalizedPattern.index(after: index)
            }
        }
        expression += (isDirectory && normalizedPattern.hasSuffix("/**")) ? "(?:/.*)?$" : "$"
        return path.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
            || (normalizedPattern.hasSuffix("/**") && path.caseInsensitiveCompare(String(normalizedPattern.dropLast(3))) == .orderedSame)
    }
}

private extension SearchSources {
    struct Transcript {
        let relativePath: String
        let json: String
    
        private struct Manifest: Decodable {
            let version: Int
            let transcriptBaseHash: String?
        }
    
        static func read(relativePath: String, workspaceRoot: URL) throws -> Transcript? {
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
            return Transcript(relativePath: directory + (fromJSON ? "/transcript.json" : "/transcript.txt"),
                json: String(decoding: pair.json, as: UTF8.self))
        }
    }
}
