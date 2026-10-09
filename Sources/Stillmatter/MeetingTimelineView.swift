import SwiftUI

/// The source-aligned events shown in the meeting's transcription page.
struct MeetingTimelineMoment: Identifiable {
    enum Kind: String, CaseIterable { case transcript = "Transcript", decision = "Decisions", action = "Actions" }
    let id: String
    let seconds: Double
    let kind: Kind
    let text: String
    let context: String
    let seekSeconds: Double?
}

struct MeetingTimelineView: View {
    let moments: [MeetingTimelineMoment]
    let hasAudio: Bool
    let seek: (MeetingTimelineMoment) -> Void
    @State private var included = Set(MeetingTimelineMoment.Kind.allCases)

    private let ink = Color(red: 0.93, green: 0.95, blue: 0.94)
    private let muted = Color(red: 0.63, green: 0.71, blue: 0.73)
    private let accent = Color(red: 0.39, green: 0.78, blue: 0.73)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Transcript timeline").font(.system(size: 18, weight: .semibold))
                Spacer()
                Text(hasAudio ? "Select a moment to seek" : "Audio unavailable · reading only")
                    .font(.system(size: 12)).foregroundStyle(muted)
            }
            HStack(spacing: 8) {
                ForEach(MeetingTimelineMoment.Kind.allCases, id: \.self) { kind in
                    Button(kind.rawValue) {
                        if included.contains(kind) { included.remove(kind) } else { included.insert(kind) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(included.contains(kind) ? accent.opacity(0.22) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(included.contains(kind) ? accent : muted.opacity(0.4)))
                    .accessibilityAddTraits(included.contains(kind) ? .isSelected : [])
                }
            }
            let visible = moments.filter { included.contains($0.kind) }
            if visible.isEmpty {
                Text(moments.isEmpty ? "No timestamped transcript or cited outcomes available yet." : "No moments in the selected filters.")
                    .foregroundStyle(muted).padding(.vertical, 24)
            }
            ForEach(visible) { moment in
                HStack(alignment: .top, spacing: 14) {
                    Text(Self.time(moment.seconds))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.54, green: 0.72, blue: 0.94))
                        .frame(width: 62, alignment: .leading)
                        .padding(.top, 19)
                    Button { seek(moment) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(moment.kind == .transcript ? "TRANSCRIPT" : moment.kind == .decision ? "DECISION" : "ACTION")
                                .font(.system(size: 10, weight: .bold)).tracking(1.3).foregroundStyle(accent)
                            Text(moment.text).font(.system(size: 14, weight: .semibold)).foregroundStyle(ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(moment.context).font(.system(size: 12)).foregroundStyle(muted)
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0.13, green: 0.20, blue: 0.23))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(muted.opacity(0.22)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasAudio || moment.seekSeconds == nil)
                    .accessibilityLabel("\(Self.time(moment.seconds)), \(moment.kind.rawValue), \(moment.text)" + (hasAudio && moment.seekSeconds != nil ? ", seek audio" : ", audio seek unavailable"))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(ink)
        .background(Color(red: 0.09, green: 0.16, blue: 0.18))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(muted.opacity(0.22)))
    }

    private static func time(_ seconds: Double) -> String {
        let value = Int(seconds)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
