import Foundation

public enum MeetingOutcomeKind: String, Codable, CaseIterable {
    case decision, question, issue
}

/// A canonical Decision or Open Item. Source metadata survives ordinary text edits.
public struct MeetingOutcomeEntry: Equatable, Identifiable {
    public let id: String
    public var text: String
    public var owner: String?
    public var kind: MeetingOutcomeKind
    public var resolved: Bool
    public var citations: [MeetingOutcomeCitation]

    public init(id: String = UUID().uuidString.lowercased(), text: String = "", owner: String? = nil,
                kind: MeetingOutcomeKind, resolved: Bool = false, citations: [MeetingOutcomeCitation] = []) {
        self.id = id; self.text = text; self.owner = owner; self.kind = kind
        self.resolved = resolved; self.citations = citations
    }
}

/// Edits one identified Markdown line while retaining surrounding prose and metadata.
public enum MeetingOutcomeDocument {
    private static func metadata(_ line: String) throws -> (Range<String.Index>, MeetingItemMetadata)? {
        guard let range = line.range(of: "<!-- sm-item:") else { return nil }
        guard line.hasSuffix(" -->") else { throw MeetingManagementError.retryRejected("Close the item metadata comment before editing.") }
        let data = Data(line[range.upperBound..<line.index(line.endIndex, offsetBy: -4)].utf8)
        let item = try JSONDecoder().decode(MeetingItemMetadata.self, from: data)
        return (range, item)
    }

    public static func entries(in markdown: String, defaultKind: MeetingOutcomeKind) throws -> [MeetingOutcomeEntry] {
        try markdown.components(separatedBy: "\n").compactMap { raw in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            guard let (range, item) = try metadata(line) else { return nil }
            let text = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^[-*] (?:\[[ xX]\] )?"#, with: "", options: .regularExpression)
            return MeetingOutcomeEntry(id: item.id, text: text, owner: item.owner,
                kind: item.kind ?? defaultKind, resolved: item.resolved ?? false, citations: item.citations)
        }
    }

    public static func replacing(_ entry: MeetingOutcomeEntry, in markdown: String, delete: Bool = false) throws -> String {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: entry.id) != nil, !text.isEmpty,
              !text.contains(where: { $0.isNewline }), !text.contains("<!--"),
              entry.owner?.contains(where: { $0.isNewline }) != true else {
            throw MeetingManagementError.retryRejected("Enter a nonempty single-line item without metadata comments.")
        }
        var found = false
        func render(_ old: MeetingItemMetadata?) throws -> String {
            var item = old ?? MeetingItemMetadata(v: 1, id: entry.id, owner: nil, review: "referenceOnly", origin: "manual", legacyID: nil, citations: [])
            item.owner = entry.owner.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
            item.kind = entry.kind; item.resolved = entry.kind == .decision ? nil : entry.resolved
            item.citations = entry.citations
            return "- " + text + " <!-- sm-item:" + String(decoding: try JSONEncoder().encode(item), as: UTF8.self) + " -->"
        }
        var lines = try markdown.components(separatedBy: "\n").compactMap { raw -> String? in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            guard let (_, item) = try metadata(line), item.id == entry.id else { return raw }
            guard !found else { throw MeetingManagementError.retryRejected("Duplicate item identity requires repair.") }
            found = true
            return try delete ? nil : render(item)
        }
        if !found {
            guard !delete else { throw MeetingManagementError.retryRejected("The item no longer exists. Reload Latest.") }
            lines.append(try render(nil))
        }
        return lines.joined(separator: "\n")
    }
}
