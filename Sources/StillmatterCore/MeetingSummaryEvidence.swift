import Foundation

/// The narrative is grounded independently of the structured outcome arrays.
enum MeetingSummaryEvidence {
    static func narrative(in markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var collecting = false
        var body: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let heading = trimmed.hasPrefix("#")
                ? String(trimmed.drop(while: { $0 == "#" || $0.isWhitespace })).trimmingCharacters(in: .whitespaces)
                : nil
            if heading == "Summary" { collecting = true; continue }
            if collecting, let heading, ["Decisions", "My action items", "Other action items", "Open questions"].contains(heading) { break }
            if collecting { body.append(line) }
        }
        return body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func citedSegmentIDs(in markdown: String, transcript: TranscriptDocument) throws -> Set<String> {
        let body = narrative(in: markdown)
        if transcript.segments.isEmpty {
            guard body == "No speech was detected." else {
                throw MeetingSummaryError.invalidExtraction("An empty Transcript must have an explicit no-speech Summary.")
            }
            return []
        }
        let known = Set(transcript.segments.map(\.id))
        let expression = try NSRegularExpression(pattern: #"\[([^\[\]]+)\]"#)
        var all: Set<String> = []
        let paragraphs = body.components(separatedBy: "\n\n").flatMap { paragraph in
            paragraph.hasPrefix("- ") || paragraph.hasPrefix("* ") ? paragraph.components(separatedBy: .newlines) : [paragraph]
        }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !paragraphs.isEmpty else { throw MeetingSummaryError.invalidExtraction("Summary narrative is missing.") }
        for (index, paragraph) in paragraphs.enumerated() {
            if paragraph.hasPrefix("#"), !paragraph.contains("\n") { continue }
            let matches = expression.matches(in: paragraph, range: NSRange(paragraph.startIndex..., in: paragraph))
            let ids = Set(matches.compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: paragraph) else { return nil }
                return String(paragraph[range])
            })
            guard !ids.isEmpty, ids.isSubset(of: known) else {
                throw MeetingSummaryError.invalidSummaryCitation(paragraph: index + 1, missing: ids.isEmpty)
            }
            try validateQuotes(in: paragraph, sources: transcript.segments.filter { ids.contains($0.id) }.map(\.text))
            all.formUnion(ids)
        }
        guard !all.isEmpty else { throw MeetingSummaryError.invalidExtraction("Summary narrative must cite Transcript evidence.") }
        return all
    }

    static func validateQuotes(in text: String, sources: [String]) throws {
        let quotes = try NSRegularExpression(pattern: #"[\"“]([^\"”]+)[\"”]"#)
        for match in quotes.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let quote = String(text[Range(match.range(at: 1), in: text)!])
            guard sources.contains(where: { $0.contains(quote) }) else {
                throw MeetingSummaryError.invalidExtraction("Quoted text must match the cited Transcript evidence exactly.")
            }
        }
    }

    static func render(narrative: String, extraction: MeetingSummaryExtraction) -> String {
        func items(_ outcomes: [MeetingOutcome]) -> String {
            outcomes.isEmpty ? "-" : outcomes.map { item in
                "- \(item.text) " + item.citations.map { "[\($0.segmentID)]" }.joined(separator: " ")
            }.joined(separator: "\n")
        }
        return """
        ---
        type: meeting-summary
        schema_version: 1
        meeting: \(extraction.meeting)
        transcript: \(extraction.transcript)
        generated_at: \(ISO8601DateFormatter().string(from: Date()))
        ---

        # Summary

        \(narrative)

        ## Decisions

        \(items(extraction.decisions))

        ## My action items

        \(items(extraction.myActionItems))

        ## Other action items

        \(items(extraction.otherActionItems))

        ## Open questions

        \(items(extraction.openQuestions))
        """
    }
}
