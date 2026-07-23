import SwiftUI

/// One scrolling column of segments — used twice in ContentView side by side
/// (Transcription on the left, Translation on the right). Both columns render
/// the same segments in the same order so row N lines up across the split.
struct TranscriptColumn: View {
    let title: String
    let segments: [Segment]
    let languageTagForSegment: (Segment) -> String
    let textForSegment: (Segment) -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(segments) { segment in
                            SegmentRow(languageTag: languageTagForSegment(segment), text: textForSegment(segment))
                                .id(segment.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: segments.last?.id) { _, lastId in
                    guard let lastId else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
                .onChange(of: segments.last?.translatedText) { _, _ in
                    guard let lastId = segments.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
