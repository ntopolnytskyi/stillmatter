import Foundation
import StillmatterCore

/// An immutable presentation of a saved phrase; its ID and time always refer to the source.
public struct TranscriptReaderPhrase: Equatable, Identifiable {
    public enum Kind: String, CaseIterable {
        case transcript = "Transcript", decision = "Decisions", action = "Actions", question = "Questions"
        public var caption: String {
            switch self { case .transcript: return "TRANSCRIPT"; case .decision: return "DECISION"; case .action: return "ACTION"; case .question: return "QUESTION" }
        }
    }
    public var metadata: String {
        if kind == .transcript {
            let initials = speaker.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
            return "\(initials)  \(speaker)"
        }
        return ([context, speaker] + chips.filter { !context.contains($0) }).filter { !$0.isEmpty }.joined(separator: " · ")
    }
    public let kind: Kind
    public let sourceSegmentID: String
    public let context: String
    public let id: String
    public let seconds: Double
    public let speaker: String
    public let chips: [String]
    public let text: String
    public let seekSeconds: Double?

    public init(id: String, seconds: Double, speaker: String, text: String, seekSeconds: Double?,
                kind: Kind = .transcript, sourceSegmentID: String? = nil, context: String? = nil) {
        self.kind = kind
        self.sourceSegmentID = sourceSegmentID ?? id
        self.context = context ?? speaker
        self.id = id
        self.seconds = seconds
        self.speaker = speaker
        if kind == .action {
            let tags = ItemTags.read(text).map { "#" + $0 }
            let pattern = #"(?<!\S)done:\s*(\d{4}-\d{2}-\d{2})(?=$|\s)"#
            let regex = try! NSRegularExpression(pattern: pattern)
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            let dates = matches.map { "done:" + (text as NSString).substring(with: $0.range(at: 1)) }
            let withoutDates = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            self.text = ItemTags.removingTags(from: withoutDates).trimmingCharacters(in: .whitespacesAndNewlines)
            let status = context?.components(separatedBy: " · ").dropFirst().first
            self.chips = tags + [status].compactMap { $0 } + dates
        } else {
            self.text = text
            self.chips = []
        }
        self.seekSeconds = seekSeconds
    }
}
