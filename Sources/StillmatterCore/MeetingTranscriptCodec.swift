import Foundation
import CryptoKit

/// Lossless LF-framed plain text and JSON representations of one Transcript.
/// Only one changed representation can advance the recorded synchronized base.
enum MeetingTranscriptCodec {
    private static let columns = ["id", "start", "end", "track", "language", "speaker", "text"]
    private static let heading = "Stillmatter Transcript v2"

    static func encodeJSON(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    static func document(_ data: Data, path: String) throws -> TranscriptDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let document = try decoder.decode(TranscriptDocument.self, from: data)
            var ids: Set<String> = []
            guard document.schemaVersion == TranscriptDocument.currentSchemaVersion,
                  document.segments.allSatisfy({ segment in
                      !segment.id.isEmpty && ids.insert(segment.id).inserted && segment.startSeconds.isFinite &&
                      segment.endSeconds.isFinite && segment.startSeconds >= 0 && segment.endSeconds >= segment.startSeconds
                  }) else { throw MeetingManagementError.malformed("Invalid Transcript version, segment identity or timing in \(path).") }
            return document
        } catch {
            throw MeetingManagementError.malformed("Could not read Transcript \(path): \(error.localizedDescription) Restore valid JSON or text and Reload Latest.")
        }
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func canonicalJSON(_ data: Data) throws -> Data {
        try encodeJSON(JSONSerialization.jsonObject(with: data))
    }

    static func text(_ json: Data) throws -> Data {
        _ = try document(json, path: "transcript.json")
        guard var object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let segments = object.removeValue(forKey: "segments") as? [[String: Any]] else {
            throw MeetingManagementError.malformed("Could not read Transcript JSON structure. Restore valid Transcript data and Reload Latest.")
        }
        var lines = [heading, String(decoding: try encodeJSON(object), as: UTF8.self), (columns + ["extra"]).joined(separator: "\t")]
        for segment in segments {
            let extra = segment.filter { !columns.contains($0.key) }
            let cells = try columns.map { column in
                guard let value = segment[column] else {
                    throw MeetingManagementError.malformed("Transcript segment is missing its \(column) field. Restore complete segment data and Reload Latest.")
                }
                return String(decoding: try encodeJSON(value), as: UTF8.self)
            }
            lines.append((cells + [String(decoding: try encodeJSON(extra), as: UTF8.self)]).joined(separator: "\t"))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func json(_ text: Data, path: String) throws -> Data {
        guard let text = String(data: text, encoding: .utf8) else {
            throw MeetingManagementError.malformed("\(path) is not UTF-8. Restore readable Transcript text.")
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count >= 3, lines[0] == heading, lines[2] == (columns + ["extra"]).joined(separator: "\t"),
              var header = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any] else {
            throw MeetingManagementError.malformed("\(path) needs the Transcript header and stable timed segment columns. Restore them and Reload Latest.")
        }
        var segments: [[String: Any]] = []
        for line in lines.dropFirst(3) {
            let cells = line.components(separatedBy: "\t")
            guard cells.count == 8, var segment = try JSONSerialization.jsonObject(with: Data(cells[7].utf8)) as? [String: Any],
                  !columns.contains(where: { segment[$0] != nil }) else {
                throw MeetingManagementError.malformed("Invalid segment row in \(path). Keep all eight columns and original timing.")
            }
            for (index, key) in columns.enumerated() {
                segment[key] = try JSONSerialization.jsonObject(with: Data(cells[index].utf8), options: .fragmentsAllowed)
            }
            segments.append(segment)
        }
        header["segments"] = segments
        let data = try encodeJSON(header)
        _ = try document(data, path: path)
        return data
    }

    static func reconcile(baseHash: String?, text: Data?, json: Data?, path: String) throws -> (json: Data, text: Data)? {
        guard text != nil || json != nil else { return nil }
        let fromText = try text.map { try self.json($0, path: path + ".txt") }
        let fromJSON: Data?
        do { fromJSON = try json.map { try canonicalJSON($0) } }
        catch { throw MeetingManagementError.malformed("\(path).json is malformed. Restore valid Transcript JSON and Reload Latest.") }
        let chosen: Data
        switch (fromText, fromJSON) {
        case let (text?, json?) where text != json:
            if hash(text) == baseHash { chosen = json }
            else if hash(json) == baseHash { chosen = text }
            else { throw MeetingManagementError.malformed("Both \(path).txt and .json changed. Both files are preserved; resolve their conflicting Transcript edits before Reload Latest.") }
        case let (text?, _): chosen = text
        case let (_, json?): chosen = json
        default: return nil
        }
        _ = try document(chosen, path: path)
        return (chosen, try self.text(chosen))
    }
}
