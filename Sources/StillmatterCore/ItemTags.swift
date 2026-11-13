import Foundation

/// Inline Markdown tags; links, inline code and identity comments are never tag storage.
public enum ItemTags {
    public static let reserved: Set<String> = ["ai-gen", "need-approve"]
    private static let tokens = try! NSRegularExpression(pattern: #"\[\[[^\]]*\]\]|`[^`]*`|<!--.*?-->|(?<!\S)#([\p{L}\p{N}][\p{L}\p{N}_-]*)(?=$|\s)"#)

    private static func matches(_ text: String) -> [NSTextCheckingResult] {
        tokens.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter { $0.range(at: 1).location != NSNotFound }
    }
    public static func read(_ text: String) -> [String] {
        var seen: Set<String> = []
        return matches(text).compactMap { match in
            let tag = (text as NSString).substring(with: match.range(at: 1))
            return seen.insert(tag).inserted ? tag : nil
        }
    }
    public static func removingTags(from text: String) -> String {
        replacing(in: text, with: [])
    }
    static func replacing(in text: String, with tags: [String]) -> String {
        var result = text
        for match in matches(text).reversed() {
            let tag = (text as NSString).substring(with: match.range(at: 1))
            guard !tags.contains(tag), let range = Range(match.range, in: result) else { continue }
            let start = range.lowerBound > result.startIndex && result[result.index(before: range.lowerBound)] == " " ? result.index(before: range.lowerBound) : range.lowerBound
            result.removeSubrange(start..<range.upperBound)
        }
        var seen = Set(read(result))
        let additions = tags.filter { seen.insert($0).inserted }.map { "#" + $0 }
        if !additions.isEmpty {
            let index = result.range(of: " <!-- sm-item:")?.lowerBound ?? (result.hasSuffix("\r") ? result.index(before: result.endIndex) : result.endIndex)
            result.insert(contentsOf: " " + additions.joined(separator: " "), at: index)
        }
        return result
    }
    static func validate(_ tags: [String], ordinaryOnly: Bool = true) throws {
        for tag in tags {
            guard tag.range(of: #"^[\p{L}\p{N}][\p{L}\p{N}_-]*$"#, options: .regularExpression) != nil,
                  !ordinaryOnly || !reserved.contains(tag) else {
                throw MeetingManagementError.malformed("Use a tag name containing letters, numbers, underscores or hyphens. ai-gen and need-approve are managed by the app.")
            }
        }
    }
}

/// AI has only an additive operation. Unknown mutation keys fail decoding rather than
/// being silently ignored (text/owner/state/removals are not part of this interface).
public struct AIItemTagAddition: Codable, Equatable {
    public let itemID: String
    public let tags: [String]
    public init(itemID: String, tags: [String]) { self.itemID = itemID; self.tags = tags }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        guard Set(values.allKeys.map(\.stringValue)) == ["item_id", "tags"] else {
            throw MeetingManagementError.malformed("AI tag patches may contain only item_id and tags.")
        }
        itemID = try values.decode(String.self, forKey: Key(stringValue: "item_id")!)
        tags = try values.decode([String].self, forKey: Key(stringValue: "tags")!)
        try ItemTags.validate(tags)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        try values.encode(itemID, forKey: Key(stringValue: "item_id")!)
        try values.encode(tags, forKey: Key(stringValue: "tags")!)
    }
}

public extension TodoItem { var tags: [String] { ItemTags.read(rawText) } }
public extension MeetingReviewItem { var tags: [String] { ItemTags.read(rawLine) } }

public enum ItemTagMutation {
    case set(itemID: String, expected: [String], tags: [String])
    case create(String)
    case rename(String, to: String)
    case delete(String)
}

public struct ItemTagSelection: Equatable {
    public let itemID: String
    public let tags: [String]
    public let catalog: [String]
    public init(itemID: String, tags: [String], catalog: [String]) {
        self.itemID = itemID; self.tags = tags; self.catalog = catalog
    }
}
