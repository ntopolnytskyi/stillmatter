import SwiftUI

/// Source-aligned events in a single chronological, bounded transcription timeline.
struct MeetingTimelineMoment: Identifiable {
    enum Kind: String, CaseIterable { case transcript = "Transcript", decision = "Decisions", action = "Actions" }
    let id: String
    let seconds: Double
    let kind: Kind
    let text: String
    let context: String
    let seekSeconds: Double?
}

/// Pure selection policy: search covers the entire recording, while ordinary browsing
/// materializes only one 15-minute window. Filters apply independently in either mode.
struct MeetingTimelineSelection {
    static let window = 15.0 * 60
    static func visible(_ moments: [MeetingTimelineMoment], included: Set<MeetingTimelineMoment.Kind>,
                        position: Double, query: String) -> [MeetingTimelineMoment] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = floor(max(0, position) / window) * window
        return moments.filter { moment in
            included.contains(moment.kind) && (term.isEmpty
                ? moment.seconds >= start && moment.seconds < start + window
                : moment.text.localizedStandardContains(term) || moment.context.localizedStandardContains(term))
        }.sorted { $0.seconds < $1.seconds }
    }
}

struct MeetingTimelineView: View {
    let moments: [MeetingTimelineMoment]
    let duration: Double
    let hasAudio: Bool
    let seek: (MeetingTimelineMoment) -> Void
    @State private var included = Set(MeetingTimelineMoment.Kind.allCases)
    @State private var position = 0.0
    @State private var hour = 0
    @State private var query = ""
    @State private var resultPage = 0

    private var ink: Color { GraphiteFocusSwiftUI.primary }
    private var muted: Color { GraphiteFocusSwiftUI.metadata }
    private var accent: Color { GraphiteFocusSwiftUI.accent }
    private var lastWindow: Double { max(0, floor(max(0, duration - 0.001) / MeetingTimelineSelection.window) * MeetingTimelineSelection.window) }
    private var start: Double { floor(position / MeetingTimelineSelection.window) * MeetingTimelineSelection.window }
    private var hourCount: Int { max(1, Int(ceil(max(duration, 1) / 3600))) }

    var body: some View {
        VStack(alignment: .leading, spacing: GraphiteFocusPresentation.Space.panel) {
            HStack {
                Text("Transcript timeline").font(GraphiteFocusSwiftUI.sectionHeading)
                Spacer()
                Text(hasAudio ? "Select a timecode to seek" : "Audio unavailable · reading only")
                    .font(GraphiteFocusSwiftUI.metadataFont).foregroundStyle(muted)
            }
            filters
            navigation
            Divider()
            results
        }
        .graphitePanel()
    }

    private var filters: some View {
        HStack(spacing: GraphiteFocusPresentation.Space.compact) {
                ForEach(MeetingTimelineMoment.Kind.allCases, id: \.self) { kind in
                    Button(kind.rawValue) {
                        if included.contains(kind) { included.remove(kind) } else { included.insert(kind) }
                    }
                    .buttonStyle(.bordered).font(GraphiteFocusSwiftUI.control)
                    .tint(included.contains(kind) ? accent : GraphiteFocusSwiftUI.secondary)
                    .accessibilityAddTraits(included.contains(kind) ? .isSelected : [])
                }
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading) {
            searchControls
            windowControls
        }
    }

    private var searchControls: some View {
            HStack {
                hourPicker
                TextField("Search entire recording…", text: $query).textFieldStyle(.roundedBorder)
                    .onChange(of: query) { _ in resultPage = 0 }
                    .accessibilityLabel("Search entire recording")
            }.font(GraphiteFocusSwiftUI.metadataFont)
    }

    private var hourPicker: some View {
        Picker("Jump to", selection: $hour) {
            ForEach(0..<hourCount, id: \.self) { index in
                Text("Hour \(index + 1)").tag(index)
            }
        }.frame(minWidth: 170) // graphite-focus-native-exception: native hour picker minimum width
        .onChange(of: hour) { newHour in position = Double(newHour * 3600) }
    }

    private var visibleCount: Int {
        MeetingTimelineSelection.visible(moments, included: included, position: position, query: query).count
    }

    private var windowControls: some View {
            HStack {
                if query.isEmpty {
                    Text("\(Self.time(start))–\(Self.time(max(start, min(start + MeetingTimelineSelection.window, duration)))) · 15 minute window")
                } else {
                    Text("Search results across entire recording")
                }
                Spacer()
                Button("Previous") {
                    if query.isEmpty { position = max(0, start - MeetingTimelineSelection.window) }
                    else { resultPage = max(0, resultPage - 1) }
                }.disabled(query.isEmpty ? start == 0 : resultPage == 0)
                Button("Next") {
                    if query.isEmpty { position = min(lastWindow, start + MeetingTimelineSelection.window) }
                    else { resultPage += 1 }
                }.disabled(query.isEmpty ? start >= lastWindow : (resultPage + 1) * 100 >= visibleCount)
            }.font(GraphiteFocusSwiftUI.metadataFont).foregroundStyle(muted)
    }

    private var results: some View {
        let visible = MeetingTimelineSelection.visible(moments, included: included, position: position, query: query)
        return VStack(alignment: .leading, spacing: GraphiteFocusPresentation.Space.compact) {
            if visible.isEmpty {
                Text(!query.isEmpty ? "No matches in this recording." : moments.isEmpty
                     ? "No timestamped transcript or cited outcomes available yet." : "No moments in this window or selected filters.")
                    .foregroundStyle(muted).padding(.vertical, GraphiteFocusPresentation.Space.page)
            }
            // A broad search can return many hits; cap the rendered batch while retaining whole-recording matches.
            ForEach(Array(visible.dropFirst(query.isEmpty ? 0 : resultPage * 100).prefix(100))) { moment in
                HStack(alignment: .top, spacing: GraphiteFocusPresentation.Space.panel) {
                    Button(Self.time(moment.seconds)) { seek(moment) }
                        .buttonStyle(.borderless).font(GraphiteFocusSwiftUI.numeric)
                        .foregroundStyle(accent).frame(minWidth: 76, alignment: .leading) // graphite-focus-native-exception: timecode column aligns chronologically
                        .disabled(!hasAudio || moment.seekSeconds == nil)
                        .accessibilityLabel("Seek to \(Self.time(moment.seconds))")
                    VStack(alignment: .leading, spacing: GraphiteFocusPresentation.Space.compact) {
                        Text(moment.kind == .transcript ? "TRANSCRIPT" : moment.kind == .decision ? "DECISION" : "ACTION")
                            .font(GraphiteFocusSwiftUI.caption).foregroundStyle(accent)
                        Text(moment.text).font(GraphiteFocusSwiftUI.rowTitle).foregroundStyle(ink)
                        Text(moment.context).font(GraphiteFocusSwiftUI.metadataFont).foregroundStyle(muted)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(GraphiteFocusPresentation.Space.dense)
                }
            }
            if !query.isEmpty && visible.count > 100 {
                Text("Results \(resultPage * 100 + 1)–\(min((resultPage + 1) * 100, visible.count)) of \(visible.count)")
                    .foregroundStyle(muted)
            }
        }
    }

    private static func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}
