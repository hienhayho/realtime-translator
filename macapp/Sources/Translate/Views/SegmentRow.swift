import SwiftUI

/// Renders one segment's text plus a small language tag above it (e.g.
/// "[Vietnamese]" on the Transcription tab, "[English]" on the Translation
/// tab when that segment's source was English). `nil` text (translation not
/// back yet) shows a loading placeholder.
struct SegmentRow: View {
    let languageTag: String
    let text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("[\(languageTag)]")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if let text {
                Text(text)
                    .font(.body)
                    .transition(.opacity)
            } else {
                Text("…")
                    .font(.body)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .animation(.easeIn(duration: 0.2), value: text)
    }
}
